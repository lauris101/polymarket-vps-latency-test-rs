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
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv().ok();
    let args = Args::parse();

    let pk_str = env::var("PK").expect("PK missing in .env");
    let chain_id = 137;
    let host = "https://clob.polymarket.com";

    println!("\n--- 🦅 Preparing Optimized Rust Trade ---");

    // Parse Signer
    let signer: PrivateKeySigner = pk_str
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid Private Key"))?;
    let signer = signer.with_chain_id(Some(chain_id));

    // ⚡ OPTIMIZATION 1: Disable server_time (use local clock)
    let t0 = Instant::now();
    let config = Config::builder()
        .use_server_time(false) // ← CRITICAL: Saves 10-20ms per request
        .build();

    let client = Client::new(host, config)?
        .authentication_builder(&signer)
        .signature_type(SignatureType::GnosisSafe)
        .authenticate()
        .await?;

    let t1 = Instant::now();
    println!("✅ Auth & Setup Time: {}ms", (t1 - t0).as_millis());

    // ⚡ OPTIMIZATION 2: Pre-parse order parameters (avoid repeated parsing)
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    let price_d = Decimal::from_str(&format!("{:.2}", args.price))?;
    let size_d = Decimal::from_str(&args.size.to_string())?;
    let token_id_u256 = U256::from_str_radix(&args.token_id, 10)?;

    // ⚡ OPTIMIZATION 3: Pre-warm metadata caches
    println!("🔥 Warming caches...");
    let cache_start = Instant::now();

    // Fetch all metadata in parallel
    let (tick_size_res, neg_risk_res, fee_rate_res) = tokio::join!(
        client.tick_size(token_id_u256),
        client.neg_risk(token_id_u256),
        client.fee_rate_bps(token_id_u256)
    );

    tick_size_res?;
    neg_risk_res?;
    fee_rate_res?;

    println!(
        "✅ Caches warmed in {}ms",
        cache_start.elapsed().as_millis()
    );
    println!("---------------------------------------------------");

    // --- LOOP 3 TIMES ---
    for i in 1..=3 {
        println!("\n🚀 Sending Order #{}...", i);
        let t_start = Instant::now();

        // Build order (caches are pre-warmed, so this is fast)
        let limit_order = client
            .limit_order()
            .token_id(token_id_u256)
            .price(price_d)
            .size(size_d)
            .side(side)
            .order_type(OrderType::GTC)
            .build()
            .await?;

        let sign_start = Instant::now();
        let signed_order = client.sign(&signer, limit_order).await?;
        let sign_time = sign_start.elapsed().as_millis();

        let post_start = Instant::now();
        let response = client.post_order(signed_order).await?;
        let post_time = post_start.elapsed().as_millis();

        let total_latency = t_start.elapsed().as_millis();

        println!("✅ Order #{} Successful!", i);
        println!("⏱️  Total Latency: {}ms", total_latency);
        println!("   ├─ Sign: {}ms", sign_time);
        println!("   └─ POST: {}ms", post_time);
        println!("🆔 Order ID: {}", response.order_id);

        if i < 3 {
            println!("... Sleeping 1s ...");
            sleep(Duration::from_millis(1000)).await;
        }
    }

    Ok(())
}
