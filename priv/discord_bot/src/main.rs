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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = env::var("DISCORD_TOKEN").expect("DISCORD_TOKEN must be set");
    let channel_id: u64 = env::var("DISCORD_CHANNEL")
        .expect("DISCORD_CHANNEL must be set")
        .parse()
        .expect("DISCORD_CHANNEL must be a valid channel ID");

    let channel_id = ChannelId::new(channel_id);

    // Set gateway intents
    let intents = GatewayIntents::GUILD_MESSAGES | GatewayIntents::MESSAGE_CONTENT;

    let mut client = Client::builder(&token, intents)
        .event_handler(Handler { channel_id })
        .await
        .expect("Error creating client");

    let http = client.http.clone();
    let cancel_token = CancellationToken::new();
    let cancel_clone = cancel_token.clone();

    // Spawn stdin handler
    let stdin_handle = tokio::spawn(handle_stdin(http, channel_id, cancel_clone));

    // Handle Ctrl+C
    let cancel_for_signal = cancel_token.clone();
    tokio::spawn(async move {
        tokio::signal::ctrl_c().await.ok();
        cancel_for_signal.cancel();
    });

    // Start Discord client
    tokio::select! {
        result = client.start() => {
            if let Err(why) = result {
                eprintln!("Client error: {:?}", why);
            }
        }
        _ = stdin_handle => {
            // stdin handler finished
        }
    }

    Ok(())
}
