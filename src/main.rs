use anyhow::Result;
use clap::Parser;
use dotenv::dotenv;
use std::{env, str::FromStr, time::Instant};
use tokio::time::{sleep, Duration};

// SDK Imports
use polymarket_client_sdk::clob::types::{OrderType, Side, SignatureType};
use polymarket_client_sdk::clob::{Client, Config};
use polymarket_client_sdk::types::Decimal;

// Alloy Imports
use alloy::primitives::U256;
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::Signer;

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    token_id: String,
    #[arg(long)]
    price: f64,
    #[arg(long)]
    size: f64,
    #[arg(long, default_value = "BUY")]
    side: String,
    #[arg(long, default_value = "3")]
    iterations: usize,
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv().ok();
    let args = Args::parse();

    let pk_str = env::var("PK").expect("PK missing in .env");
    let chain_id = 137;
    let host = "https://clob.polymarket.com";

    println!("\n--- ⚡ Live Strategy Bot (Per-Order Optimized) ---");

    let setup_start = Instant::now();

    // Parse Signer
    let signer: PrivateKeySigner = pk_str
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid Private Key"))?;
    let signer = signer.with_chain_id(Some(chain_id));

    // ⚡ CRITICAL: use_server_time = false (saves 10-20ms per order)
    let config = Config::builder().use_server_time(false).build();

    let client = Client::new(host, config)?
        .authentication_builder(&signer)
        .signature_type(SignatureType::GnosisSafe)
        .authenticate()
        .await?;

    // Pre-parse parameters (do once, reuse for all orders)
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    let price_d = Decimal::from_str(&format!("{:.2}", args.price))?;
    let size_d = Decimal::from_str(&args.size.to_string())?;
    let token_id_u256 = U256::from_str_radix(&args.token_id, 10)?;

    // ⚡ Pre-warm caches in parallel (one-time cost)
    let (tick_res, neg_res, fee_res) = tokio::join!(
        client.tick_size(token_id_u256),
        client.neg_risk(token_id_u256),
        client.fee_rate_bps(token_id_u256)
    );

    tick_res?;
    neg_res?;
    fee_res?;

    let setup_time = setup_start.elapsed().as_millis();
    println!("✅ Setup complete: {}ms (one-time cost)", setup_time);
    println!("---------------------------------------------------\n");

    // Track statistics
    let mut total_latencies = Vec::new();
    let mut build_times = Vec::new();
    let mut sign_times = Vec::new();
    let mut post_times = Vec::new();

    // --- SIMULATE LIVE TRADING: Orders sent one-by-one ---
    for i in 1..=args.iterations {
        println!("🚀 Order #{} (live execution)...", i);

        let order_start = Instant::now();

        // BUILD ORDER
        let build_start = Instant::now();
        let limit_order = client
            .limit_order()
            .token_id(token_id_u256)
            .price(price_d)
            .size(size_d)
            .side(side)
            .order_type(OrderType::GTC)
            .build()
            .await?;
        let build_ms = build_start.elapsed().as_millis();

        // SIGN ORDER
        let sign_start = Instant::now();
        let signed_order = client.sign(&signer, limit_order).await?;
        let sign_ms = sign_start.elapsed().as_millis();

        // POST ORDER
        let post_start = Instant::now();
        let response = client.post_order(signed_order).await?;
        let post_ms = post_start.elapsed().as_millis();

        let total_ms = order_start.elapsed().as_millis();

        // Record stats
        total_latencies.push(total_ms);
        build_times.push(build_ms);
        sign_times.push(sign_ms);
        post_times.push(post_ms);

        println!("✅ Order #{} posted", i);
        println!("⏱️  Total: {}ms", total_ms);
        println!("   ├─ Build: {}ms (cached metadata)", build_ms);
        println!("   ├─ Sign:  {}ms (crypto)", sign_ms);
        println!("   └─ POST:  {}ms (network)", post_ms);
        println!("🆔 {}", response.order_id);

        if i < args.iterations {
            println!("... Sleeping 1s ...\n");
            sleep(Duration::from_millis(1000)).await;
        }
    }

    // Print statistics (excluding first order if warmup needed)
    let skip_first = if args.iterations > 1 { 1 } else { 0 };

    println!("\n═══════════════════════════════════════════════════");
    println!("📊 PERFORMANCE STATISTICS (excluding setup)");
    println!("═══════════════════════════════════════════════════");

    if args.iterations > skip_first {
        let steady_state: Vec<_> = total_latencies.iter().skip(skip_first).copied().collect();
        let avg = steady_state.iter().sum::<u128>() / steady_state.len() as u128;
        let min = steady_state.iter().min().unwrap();
        let max = steady_state.iter().max().unwrap();

        println!("Total Latency:");
        println!("  Average: {}ms", avg);
        println!("  Min:     {}ms", min);
        println!("  Max:     {}ms", max);

        let avg_build = build_times.iter().skip(skip_first).sum::<u128>()
            / (args.iterations - skip_first) as u128;
        let avg_sign = sign_times.iter().skip(skip_first).sum::<u128>()
            / (args.iterations - skip_first) as u128;
        let avg_post = post_times.iter().skip(skip_first).sum::<u128>()
            / (args.iterations - skip_first) as u128;

        println!("\nBreakdown (avg):");
        println!("  Build: {}ms", avg_build);
        println!("  Sign:  {}ms", avg_sign);
        println!("  POST:  {}ms", avg_post);

        // Identify bottleneck
        println!("\n🎯 Bottleneck Analysis:");
        if avg_post > avg_sign * 2 {
            println!("   Network (POST) is the limiting factor");
            println!("   → Consider VPS closer to Polymarket servers");
        } else if avg_sign > avg_post {
            println!("   Crypto (Sign) is the limiting factor");
            println!("   → Already optimized; consider release build");
        } else {
            println!("   Well balanced - near optimal for this setup");
        }
    }

    println!("═══════════════════════════════════════════════════\n");

    Ok(())
}
