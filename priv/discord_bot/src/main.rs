use serenity::{
    async_trait,
    model::{channel::Message, gateway::Ready, id::ChannelId},
    prelude::*,
};
use serde::{Deserialize, Serialize};
use serde_json;
use std::env;
use tokio::io::{self, AsyncBufReadExt, BufReader};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum ErlangMessage {
    #[serde(rename = "user_join")]
    UserJoin { username: String },
    #[serde(rename = "user_leave")]
    UserLeave { username: String },
    #[serde(rename = "match_result")]
    MatchResult { winner: String, loser: String, quip: String },
    #[serde(rename = "chat")]
    Chat { username: String, message: String },
}

#[derive(Debug, Serialize)]
struct DiscordMessage {
    #[serde(rename = "type")]
    msg_type: String,
    author: String,
    content: String,
}

struct Handler {
    channel_id: ChannelId,
}

#[async_trait]
impl EventHandler for Handler {
    async fn message(&self, _ctx: Context, msg: Message) {
        // Ignore bot messages and messages from other channels
        if msg.author.bot || msg.channel_id != self.channel_id {
            return;
        }

        let response = DiscordMessage {
            msg_type: "message".to_string(),
            author: msg.author.display_name().to_string(),
            content: msg.content,
        };

        if let Ok(json) = serde_json::to_string(&response) {
            println!("{}", json);
        }
    }

    async fn ready(&self, _: Context, ready: Ready) {
        let response = DiscordMessage {
            msg_type: "ready".to_string(),
            author: ready.user.name.clone(),
            content: "Discord bot connected".to_string(),
        };

        if let Ok(json) = serde_json::to_string(&response) {
            println!("{}", json);
        }
    }
}

async fn handle_stdin(http: std::sync::Arc<serenity::http::Http>, channel_id: ChannelId, cancel_token: CancellationToken) {
    let stdin = io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    loop {
        tokio::select! {
            _ = cancel_token.cancelled() => {
                break;
            }
            line = lines.next_line() => {
                match line {
                    Ok(Some(line)) => {
                        if let Err(e) = handle_erlang_message(&http, &channel_id, &line).await {
                            eprintln!("Error handling message: {}", e);
                        }
                    }
                    Ok(None) => break, // EOF
                    Err(e) => {
                        eprintln!("Error reading stdin: {}", e);
                        break;
                    }
                }
            }
        }
    }
}

async fn handle_erlang_message(
    http: &std::sync::Arc<serenity::http::Http>,
    channel_id: &ChannelId,
    json_line: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let message: ErlangMessage = serde_json::from_str(json_line)?;

    match message {
        ErlangMessage::UserJoin { username } => {
            let content = format!("🟢 **{}** has entered the arena", username);
            channel_id.say(http, content).await?;
        }
        ErlangMessage::UserLeave { username } => {
            let content = format!("🔴 **{}** has left the arena", username);
            channel_id.say(http, content).await?;
        }
        ErlangMessage::MatchResult { winner: _, loser: _, quip } => {
            let content = format!("⚔️ {}", quip);
            channel_id.say(http, content).await?;
        }
        ErlangMessage::Chat { username, message } => {
            let content = format!("💬 **{}**: {}", username, message);
            channel_id.say(http, content).await?;
        }
    }

    Ok(())
}

async fn create_and_start_client(
    token: &str,
    channel_id: ChannelId,
    http: std::sync::Arc<serenity::http::Http>,
    cancel_token: CancellationToken,
) -> Result<(), Box<dyn std::error::Error>> {
    // Try privileged intents first
    eprintln!("🔌 Attempting connection with privileged intents...");
    let privileged_intents = GatewayIntents::GUILD_MESSAGES | GatewayIntents::MESSAGE_CONTENT;
    let mut client = Client::builder(token, privileged_intents)
        .event_handler(Handler { channel_id })
        .await?;

    match client.start().await {
        Ok(()) => {
            eprintln!("✅ Connected with privileged intents (MESSAGE_CONTENT enabled)");
            Ok(())
        }
        Err(serenity::Error::Gateway(serenity::gateway::GatewayError::DisallowedGatewayIntents)) => {
            eprintln!("⚠️  Privileged intents not allowed, retrying with basic intents");
            eprintln!("   Enable 'Message Content Intent' in Discord Developer Portal for full functionality");

            // Create new client with basic intents only
            eprintln!("🔌 Retrying connection with basic intents...");
            let basic_intents = GatewayIntents::GUILD_MESSAGES;
            let mut basic_client = Client::builder(token, basic_intents)
                .event_handler(Handler { channel_id })
                .await?;

            match basic_client.start().await {
                Ok(()) => {
                    eprintln!("⚠️  Connected with basic intents (Discord→Lobby messages disabled)");
                    Ok(())
                }
                Err(why) => {
                    eprintln!("❌ Client error even with basic intents: {:?}", why);
                    Err(Box::new(why))
                }
            }
        }
        Err(why) => {
            eprintln!("❌ Client error: {:?}", why);
            Err(Box::new(why))
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = env::var("DISCORD_TOKEN").expect("DISCORD_TOKEN must be set");
    let channel_id: u64 = env::var("DISCORD_CHANNEL")
        .expect("DISCORD_CHANNEL must be set")
        .parse()
        .expect("DISCORD_CHANNEL must be a valid channel ID");

    let channel_id = ChannelId::new(channel_id);

    // Create a temporary client to get HTTP handle for stdin handler
    let temp_client = Client::builder(&token, GatewayIntents::empty())
        .await
        .expect("Error creating temporary client");
    let http = temp_client.http.clone();

    let cancel_token = CancellationToken::new();
    let cancel_clone = cancel_token.clone();

    // Spawn stdin handler
    let _stdin_handle = tokio::spawn(handle_stdin(http.clone(), channel_id, cancel_clone));

    // Handle Ctrl+C
    let cancel_for_signal = cancel_token.clone();
    tokio::spawn(async move {
        tokio::signal::ctrl_c().await.ok();
        cancel_for_signal.cancel();
    });

    // Start Discord client with intent fallback
    tokio::select! {
        result = create_and_start_client(&token, channel_id, http, cancel_token.clone()) => {
            if let Err(why) = result {
                eprintln!("Failed to start Discord client: {:?}", why);
            }
        }
        _ = cancel_token.cancelled() => {
            eprintln!("Shutting down...");
        }
    }

    Ok(())
}
