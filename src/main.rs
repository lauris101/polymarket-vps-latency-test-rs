use alloy::primitives::U256;
use alloy::signers::local::PrivateKeySigner; // ✅ Correct
use anyhow::Result;
use base64::{engine::general_purpose, Engine as _};
use clap::Parser;
use hmac::{Hmac, Mac};
use polymarket_client_sdk::auth::ExposeSecret;
use polymarket_client_sdk::clob::types::{OrderType, Side};
use polymarket_client_sdk::clob::{Client as SdkClient, Config};
use polymarket_client_sdk::types::Decimal;
use reqwest::{header, Client as HttpClient};
use sha2::{Digest, Sha256};
use std::env;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};
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

fn generate_l2_headers(
    api_key: &str,
    api_secret: &str,
    passphrase: &str,
    method: &str,
    path: &str,
    body_bytes: &[u8],
) -> Result<header::HeaderMap> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .to_string();

    let mut mac = Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())?;
    mac.update(timestamp.as_bytes());
    mac.update(method.as_bytes());
    mac.update(path.as_bytes());
    mac.update(body_bytes);

    let signature = general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    let mut headers = header::HeaderMap::new();
    headers.insert("POLY-API-KEY", header::HeaderValue::from_str(api_key)?);
    headers.insert(
        "POLY-API-SIGNATURE",
        header::HeaderValue::from_str(&signature)?,
    );
    headers.insert(
        "POLY-API-TIMESTAMP",
        header::HeaderValue::from_str(&timestamp)?,
    );
    headers.insert(
        "POLY-API-PASSPHRASE",
        header::HeaderValue::from_str(passphrase)?,
    );
    headers.insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("application/json"),
    );

    Ok(headers)
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv::dotenv().ok();
    let args = Args::parse();

    // ---- SIGNER (alloy) ----
    let pk = env::var("PK").expect("PK missing");
    let signer: PrivateKeySigner = pk.parse()?; // ✅ Correct
    let signer = alloy::signers::Signer::with_chain_id(signer, Some(137)); // Polygon chain

    // ---- SDK to derive proxy API credentials ----
    let host = "https://clob.polymarket.com";
    let unauth = SdkClient::new(host, Config::builder().build())?;
    println!("🔐 Deriving Proxy API credentials...");
    let creds = unauth.create_or_derive_api_key(&signer, None).await?;
    let api_key = creds.key().to_string();
    let api_secret = creds.secret().expose_secret().to_string();
    let api_passphrase = creds.passphrase().expose_secret().to_string();
    println!("✅ Proxy credentials ready (API Key: {}...)", &api_key[..8]);

    // ---- RAW HTTP CLIENT (low latency) ----
    let http = HttpClient::builder()
        .tcp_nodelay(true)
        .pool_idle_timeout(None)
        .build()?;

    let clob_url = "https://clob.polymarket.com/orders";
    let path = "/orders";
    let method = "POST";

    // ---- ORDER PARAMETERS ----
    let token_id = U256::from_str(&args.token_id)?;
    let price = Decimal::from_str(&args.price)?;
    let size = Decimal::from_str(&args.size)?;
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    // ---- PREBUILD ORDER JSON ----
    let order_payload = serde_json::json!({
        "tokenId": token_id.to_string(),
        "price": price.to_string(),
        "size": size.to_string(),
        "side": format!("{side:?}"),
        "orderType": "GTC"
    });

    let body_bytes = serde_json::to_vec(&order_payload)?;

    println!("🚀 Starting low-latency loop...");

    for i in 1..=3 {
        let headers = generate_l2_headers(
            &api_key,
            &api_secret,
            &api_passphrase,
            method,
            path,
            &body_bytes,
        )?;

        let t0 = std::time::Instant::now();
        let resp = http
            .post(clob_url)
            .headers(headers)
            .body(body_bytes.clone())
            .send()
            .await?;

        let dt = t0.elapsed().as_millis();
        let status = resp.status();
        println!("✅ Order #{} | {}ms | {}", i, dt, status);

        if !status.is_success() {
            println!("❌ {}", resp.text().await?);
        }

        sleep(Duration::from_millis(500)).await;
    }

    Ok(())
}
