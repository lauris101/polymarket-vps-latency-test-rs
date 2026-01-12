use anyhow::Result;
use chrono::Utc;
use clap::Parser;
use dotenv::dotenv;
use std::{env, str::FromStr, time::Instant};
use tokio::time::{sleep, Duration};

// SDK Imports
use polymarket_client_sdk::clob::types::{OrderType, Side, SignatureType};
use polymarket_client_sdk::clob::{Client, Config};
use polymarket_client_sdk::types::Decimal;

// Alloy Imports (v1.3.0)
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

    println!("\n--- 🦅 Preparing Rust Trade (Fixed Precision) ---");

    // Parse Signer
    let signer: PrivateKeySigner = pk_str
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid Private Key"))?;
    let signer = signer.with_chain_id(Some(chain_id));

    // Config & Auth
    let t0 = Instant::now();
    let config = Config::builder().use_server_time(true).build();

    let client = Client::new(host, config)?
        .authentication_builder(&signer)
        .signature_type(SignatureType::GnosisSafe)
        .authenticate()
        .await?;

    let t1 = Instant::now();
    println!(
        "✅ Auth & Setup Time: {:.2?}ms (This is paid only once)",
        (t1 - t0).as_millis()
    );
    println!("---------------------------------------------------");

    // 4. Prepare Order Data
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };
    let price_str = format!("{:.2}", args.price);
    let price_d = Decimal::from_str(&price_str)?;
    let size_str = args.size.to_string();
    let size_d = Decimal::from_str(&size_str)?;
    let token_id_u256 = U256::from_str_radix(&args.token_id, 10)?;

    // --- LOOP 3 TIMES ---
    for i in 1..=3 {
        println!("\n🚀 Sending Order #{}...", i);

        let t_start = Instant::now();
        let client_timestamp = Utc::now().timestamp_millis();

        // Build & Sign
        let limit_order = client
            .limit_order()
            .token_id(token_id_u256)
            .price(price_d)
            .size(size_d)
            .side(side)
            .order_type(OrderType::GTC)
            .build()
            .await?;
        let signed_order = client.sign(&signer, limit_order).await?;

        // Post
        let response = client.post_order(signed_order).await?;

        let t_end = Instant::now();
        let latency = (t_end - t_start).as_millis();

        println!("🕒 Client TS: {}", client_timestamp);
        println!("✅ Order #{} Successful!", i);
        println!("⏱️  Latency: {}ms", latency);
        println!("🆔 Response: {:?}", response);

        if i < 3 {
            println!("... Sleeping 1s to respect rate limits ...");
            sleep(Duration::from_millis(1000)).await;
        }
    }
    Ok(())
}
