use anyhow::Result;
use clap::Parser;
use dotenv::dotenv;
use std::{env, str::FromStr, time::Instant};

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
    println!("✅ Auth Time: {:.2?}ms", (t1 - t0).as_millis());

    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    // FIX 1: Format Price to strictly 2 decimal places (avoids 0.4099999 issue)
    let price_str = format!("{:.2}", args.price);
    let price_d = Decimal::from_str(&price_str)
        .map_err(|_| anyhow::anyhow!("Failed to parse price decimal"))?;

    // FIX 2: Handle Size safely as well (trimming floating point artifacts)
    // We format size to 2 decimals usually, or just stringify the float clean
    let size_str = args.size.to_string();
    let size_d = Decimal::from_str(&size_str)
        .map_err(|_| anyhow::anyhow!("Failed to parse size decimal"))?;

    // Parse Token ID
    let token_id_u256 = U256::from_str_radix(&args.token_id, 10)
        .map_err(|_| anyhow::anyhow!("Invalid Token ID format"))?;

    println!("⚡ Sending Order: Price {} | Size {}", price_str, size_str);
    let t_start = Instant::now();

    // 1. Build
    let limit_order = client
        .limit_order()
        .token_id(token_id_u256)
        .price(price_d)
        .size(size_d)
        .side(side)
        .order_type(OrderType::GTC)
        .build()
        .await?;

    // 2. Sign
    let signed_order = client.sign(&signer, limit_order).await?;

    // 3. Post
    let response = client.post_order(signed_order).await?;

    let t_end = Instant::now();
    println!(
        "✅ Order Successful! Latency: {:.2?}ms",
        (t_end - t_start).as_millis()
    );
    println!("🆔 Response: {:?}", response);
    Ok(())
}
