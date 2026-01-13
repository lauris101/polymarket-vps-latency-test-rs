use alloy::primitives::U256;
use alloy::signers::local::PrivateKeySigner;
use anyhow::Result;
use clap::Parser;
use polymarket_client_sdk::clob::types::{OrderType, Side, SignatureType};
use polymarket_client_sdk::clob::{Client as SdkClient, Config};
use polymarket_client_sdk::types::Decimal;
use reqwest::{header, Client as HttpClient};
use serde_json::Value;
use std::env;
use std::str::FromStr;
use std::time::Instant;
use tokio::time::{sleep, Duration};

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    token_id: String,
    #[arg(long)]
    price: String,
    #[arg(long)]
    size: String,
    #[arg(long, default_value = "BUY")]
    side: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv::dotenv().ok();
    let args = Args::parse();

    // ---- Signer (proxy wallet derived from EOA private key) ----
    let pk = env::var("PK").expect("PK missing");
    let signer: PrivateKeySigner = pk.parse()?;

    // ---- SDK unauthenticated client ----
    let host = "https://clob.polymarket.com";
    let unauth = SdkClient::new(host, Config::builder().build())?;
    println!("🔐 Creating / deriving proxy API credentials...");
    let creds = unauth.create_or_derive_api_key(&signer, None).await?;

    // ---- SDK authenticated signing-only client ----
    let sdk = unauth
        .authentication_builder(&signer)
        .credentials(creds)
        .signature_type(SignatureType::GnosisSafe) // important for proxy wallets
        .authenticate()
        .await?;

    // ---- HTTP client for low-latency POSTs ----
    let http = HttpClient::builder()
        .tcp_nodelay(true)
        .pool_idle_timeout(None)
        .build()?;

    // ---- Order params ----
    let token_id = U256::from_str(&args.token_id)?;
    let price = Decimal::from_str(&args.price)?;
    let size = Decimal::from_str(&args.size)?;
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    println!("🚀 Starting low-latency loop...");

    for i in 1..=3 {
        // ---- Build and sign order ----
        let unsigned = sdk
            .limit_order()
            .token_id(token_id)
            .price(price)
            .size(size)
            .side(side)
            .order_type(OrderType::GTC)
            .build()
            .await?;

        let signed = sdk.sign(&signer, unsigned).await?;

        // ---- Serialize signed order once ----
        let body_bytes = serde_json::to_vec(&signed)?;

        // ---- Send signed order directly via HTTP ----
        let t0 = Instant::now();
        let resp = http
            .post("https://clob.polymarket.com/orders")
            .header(header::CONTENT_TYPE, "application/json")
            .body(body_bytes.clone())
            .send()
            .await?;

        let dt = t0.elapsed().as_millis();
        let status = resp.status();
        println!("✅ Order #{} | {}ms | {}", i, dt, status);

        if !status.is_success() {
            let text: Value = resp
                .json()
                .await
                .unwrap_or(Value::String("Unknown error".into()));
            println!("❌ {text}");
        }

        // ---- Short delay for demonstration; adjust for actual low-latency loop ----
        sleep(Duration::from_millis(500)).await;
    }

    Ok(())
}
