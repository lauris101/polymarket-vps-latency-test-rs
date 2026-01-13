use alloy::primitives::U256;
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::Signer;
use anyhow::Result;
use base64::{engine::general_purpose, Engine as _};
use clap::Parser;
use hmac::{Hmac, Mac};
use polymarket_client_sdk::auth::ExposeSecret; // <--- Import for .expose_secret()
use polymarket_client_sdk::clob::types::{OrderType, Side, SignatureType};
use polymarket_client_sdk::clob::{Client as SdkClient, Config};
use polymarket_client_sdk::types::Decimal;
use reqwest::{header, Client as HttpClient};
use sha2::Sha256;
use std::env;
use std::str::FromStr;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tokio::time::{sleep, Duration};

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
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
    body: &str,
) -> Result<header::HeaderMap> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .to_string();

    let message = format!("{}{}{}{}", timestamp, method, path, body);

    let mut mac = Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())?;
    mac.update(message.as_bytes());
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

    // REQUIRED for proxy-derived keys
    headers.insert(
        "POLY-API-SIGNATURE-TYPE",
        header::HeaderValue::from_static("GnosisSafe"),
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

    // 1. SETUP SIGNER
    let pk_str = env::var("PK").expect("PK must be set in .env");
    let signer: PrivateKeySigner = pk_str.parse()?;
    let signer = signer.with_chain_id(Some(137));

    // 2. SETUP UNAUTHENTICATED CLIENT
    let config = Config::builder().build();
    let host = "https://clob.polymarket.com";
    let unauth_client = SdkClient::new(host, config)?;

    println!("🔐 Fetching Credentials & Deriving Proxy...");

    // 3. FETCH CREDENTIALS EXPLICITLY
    // We call this manually so we get ownership of the 'creds' struct
    let creds = unauth_client
        .create_or_derive_api_key(&signer, None)
        .await?;

    // 4. EXTRACT STRINGS (For the Raw Loop)
    // We do this NOW, while we have ownership of 'creds'
    let api_key = creds.key().to_string();
    let api_secret = creds.secret().expose_secret().to_string();
    let api_passphrase = creds.passphrase().expose_secret().to_string();

    println!("✅ Credentials Acquired! API Key: {}...", &api_key[0..8]);

    // 5. AUTHENTICATE SDK (For Signing)
    // We pass the SAME 'creds' back into the builder.
    // We MUST use GnosisSafe signature type so the SDK calculates the correct Proxy Address.
    let sdk_client = unauth_client
        .authentication_builder(&signer)
        .credentials(creds) // <--- Inject the credentials we just fetched
        .signature_type(SignatureType::GnosisSafe) // <--- Critical for Proxy
        .authenticate()
        .await?;

    // 6. SETUP RAW CLIENT
    let raw_client = HttpClient::builder()
        .tcp_nodelay(true)
        .pool_idle_timeout(None)
        .user_agent("clob_rs_client")
        .build()?;

    let clob_url = "https://clob.polymarket.com/orders";
    let path = "/orders";
    let method = "POST";

    // 7. PREPARE ORDER
    println!("\n📝 Preparing Order Data...");
    let token_id = U256::from_str(&args.token_id)?;
    let price = Decimal::from_str(&args.price)?;
    let size = Decimal::from_str(&args.size)?;
    let side = if args.side.to_uppercase() == "SELL" {
        Side::Sell
    } else {
        Side::Buy
    };

    println!("\n🚀 Starting Low-Latency Loop...");

    // 8. HOT LOOP
    for i in 1..=3 {
        // A. SIGN (Use SDK for complex Gnosis/EIP-712 logic)
        let unsigned_order = sdk_client
            .limit_order()
            .token_id(token_id)
            .price(price)
            .size(size)
            .side(side)
            .order_type(OrderType::GTC)
            .build()
            .await?;

        let signed_order = sdk_client.sign(&signer, unsigned_order).await?;
        let order_json_str = serde_json::to_string(&signed_order)?;

        // B. SEND (Use Raw Client for speed)
        let t_start = Instant::now();

        let headers = generate_l2_headers(
            &api_key,
            &api_secret,
            &api_passphrase,
            method,
            path,
            &order_json_str,
        )?;

        let response = raw_client
            .post(clob_url)
            .headers(headers)
            .body(order_json_str)
            .send()
            .await?;

        let t_end = Instant::now();
        let status = response.status();

        println!(
            "✅ Order #{} | {}ms | Status: {}",
            i,
            (t_end - t_start).as_millis(),
            status
        );

        if !status.is_success() {
            println!("   ❌ Error: {}", response.text().await?);
        }

        sleep(Duration::from_millis(1000)).await;
    }

    Ok(())
}
