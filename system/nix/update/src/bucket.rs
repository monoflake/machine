//! The bucket over S3 with the systems credentials, or a directory for a test, and a driver archive
//! over HTTPS, as `fetch.sh` and `driver.sh` read them. Written by the store lane.

use std::io;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::OnceLock;
use std::task::{Context, Poll, ready};
use std::time::Duration;

use bytes::Bytes;
use futures_util::{Stream, StreamExt};
use reqwest::redirect::Policy;
use rusty_s3::{S3Action, UrlStyle};
use tokio::io::{AsyncRead, ReadBuf};
use url::Url;

use crate::effects::{Bucket, BucketError, Download, Object};
use crate::output::Refusal;

/// The `[systems]` profile's key pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credentials {
	/// `aws_access_key_id`, letters and digits.
	pub key: String,
	/// `aws_secret_access_key`, base64's alphabet.
	pub secret: String,
}

/// Reads the `[systems]` profile from a shared credentials file, each key once, as `credential`
/// read it, refusing anything else as malformed.
pub fn credentials(text: &str) -> Result<Credentials, Refusal> {
	let key = credential(text, "aws_access_key_id").ok_or(Refusal::Credentials)?;
	let secret = credential(text, "aws_secret_access_key").ok_or(Refusal::Credentials)?;
	let key_ok = !key.is_empty() && key.bytes().all(|b| b.is_ascii_alphanumeric());
	let secret_ok =
		!secret.is_empty() && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b"/+=".contains(&b));
	if key_ok && secret_ok { Ok(Credentials { key, secret }) } else { Err(Refusal::Credentials) }
}

/// One key's value in `[systems]`, `None` unless it appears exactly once, as the awk in `fetch.sh`.
fn credential(text: &str, wanted: &str) -> Option<String> {
	let blank = |c: char| c == ' ' || c == '\t';
	let mut active = false;
	let mut found = Vec::new();
	for line in text.split('\n') {
		let line = line.strip_suffix('\r').unwrap_or(line).trim_matches(blank);
		if line.starts_with('[') {
			active = line == "[systems]";
			continue;
		}
		if !active || line.starts_with('#') || line.starts_with(';') {
			continue;
		}
		if let Some((key, value)) = line.split_once('=')
			&& key.trim_end_matches(blank) == wanted
		{
			found.push(value.trim_start_matches(blank).to_owned());
		}
	}
	let value = found.pop()?;
	found.is_empty().then_some(value)
}

/// The bucket a configuration names.
#[derive(Debug)]
pub enum Remote {
	/// A bucket over S3, path style, region `auto`.
	S3 {
		/// The bucket's name.
		bucket: String,
		/// The endpoint's host, with its port where it has one.
		host: String,
		/// The key pair requests are signed with.
		credentials: Credentials,
	},
	/// A bucket on disk, `file:///<directory>`.
	Directory(PathBuf),
}

impl Remote {
	/// The bucket for a configuration's name and endpoint, refusing a malformed name or endpoint.
	pub fn new(bucket: &str, endpoint: &str, credentials: Credentials) -> Result<Self, Refusal> {
		if bucket.starts_with("file:///")
			&& let Some(directory) = bucket.strip_prefix("file://")
		{
			return Ok(Self::Directory(PathBuf::from(directory)));
		}
		if !bucket_name(bucket) {
			return Err(Refusal::Bucket);
		}
		// The file's trailing newlines go, as the shell's command substitution dropped them.
		let endpoint = endpoint.trim_end_matches('\n');
		let host = endpoint.strip_prefix("https://").ok_or(Refusal::EndpointMalformed)?;
		let host = host.strip_suffix('/').unwrap_or(host);
		if !endpoint_host(host) {
			return Err(Refusal::EndpointMalformed);
		}
		Ok(Self::S3 { bucket: bucket.to_owned(), host: host.to_owned(), credentials })
	}
}

/// `^[a-z0-9][a-z0-9.-]*$`.
fn bucket_name(name: &str) -> bool {
	let allowed = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
	let mut bytes = name.bytes();
	bytes.next().is_some_and(allowed) && bytes.all(|b| allowed(b) || b == b'.' || b == b'-')
}

/// `[A-Za-z0-9.-]+(:[0-9]+)?`, the endpoint once its scheme and trailing slash are taken off.
fn endpoint_host(host: &str) -> bool {
	let (name, port) = match host.split_once(':') {
		Some((name, port)) => (name, Some(port)),
		None => (host, None),
	};
	let name_ok =
		!name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
	let port_ok = port.is_none_or(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
	name_ok && port_ok
}

/// How long a signed request stays valid.
const SIGNED_FOR: Duration = Duration::from_secs(300);

impl Remote {
	/// The signed URL of an object, `None` for a directory.
	fn signed(&self, key: &str) -> Result<Option<Url>, BucketError> {
		let Self::S3 { bucket, host, credentials } = self else {
			return Ok(None);
		};
		let endpoint = Url::parse(&format!("https://{host}")).map_err(|_| BucketError::Transport)?;
		let bucket = rusty_s3::Bucket::new(endpoint, UrlStyle::Path, bucket.clone(), "auto")
			.map_err(|_| BucketError::Transport)?;
		let credentials = rusty_s3::Credentials::new(&credentials.key, &credentials.secret);
		Ok(Some(bucket.get_object(Some(&credentials), key).sign(SIGNED_FOR)))
	}

	/// The file of an object in a directory bucket.
	fn file(&self, key: &str) -> Option<PathBuf> {
		match self {
			Self::Directory(directory) => Some(directory.join(key)),
			Self::S3 { .. } => None,
		}
	}
}

impl Bucket for Remote {
	async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, BucketError> {
		if let Some(file) = self.file(key) {
			return match tokio::fs::read(file).await {
				Ok(bytes) => Ok(Some(bytes)),
				Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
				Err(_) => Err(BucketError::Transport),
			};
		}
		let Some(url) = self.signed(key)? else {
			return Err(BucketError::Transport);
		};
		match request(&s3_client()?, url).await? {
			Some(response) => {
				let body = response.bytes().await.map_err(|_| BucketError::Transport)?;
				Ok(Some(body.to_vec()))
			}
			None => Ok(None),
		}
	}

	async fn open(&self, key: &str) -> Result<Option<Object>, BucketError> {
		if let Some(file) = self.file(key) {
			return match tokio::fs::File::open(file).await {
				Ok(file) => Ok(Some(Box::pin(file))),
				Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
				Err(_) => Err(BucketError::Transport),
			};
		}
		let Some(url) = self.signed(key)? else {
			return Err(BucketError::Transport);
		};
		match request(&s3_client()?, url).await? {
			Some(response) => {
				Ok(Some(Box::pin(Body { stream: response.bytes_stream().boxed(), chunk: Bytes::new() })))
			}
			None => Ok(None),
		}
	}
}

/// Sends a GET, 200 giving the response, 404 `None` and another status its code.
async fn request(
	client: &reqwest::Client,
	url: Url,
) -> Result<Option<reqwest::Response>, BucketError> {
	// reqwest's error names the URL, which carries the key's id, so it is dropped here.
	let response = client.get(url).send().await.map_err(|_| BucketError::Transport)?;
	match response.status().as_u16() {
		200 => Ok(Some(response)),
		404 => Ok(None),
		code => Err(BucketError::Status(code)),
	}
}

/// The client every bucket request shares, following no redirect, as `curl` did without `--location`.
fn s3_client() -> Result<reqwest::Client, BucketError> {
	static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
	if let Some(client) = CLIENT.get() {
		return Ok(client.clone());
	}
	crate::tls::install();
	let client = reqwest::Client::builder()
		.redirect(Policy::none())
		.build()
		.map_err(|_| BucketError::Transport)?;
	Ok(CLIENT.get_or_init(|| client).clone())
}

/// An object's body read as it arrives, an interrupted body an error naming no URL.
struct Body {
	stream: Pin<Box<dyn Stream<Item = reqwest::Result<Bytes>> + Send>>,
	chunk: Bytes,
}

impl AsyncRead for Body {
	fn poll_read(
		mut self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		buf: &mut ReadBuf<'_>,
	) -> Poll<io::Result<()>> {
		loop {
			if !self.chunk.is_empty() {
				let length = self.chunk.len().min(buf.remaining());
				let part = self.chunk.split_to(length);
				buf.put_slice(&part);
				return Poll::Ready(Ok(()));
			}
			match ready!(self.stream.poll_next_unpin(cx)) {
				Some(Ok(chunk)) => self.chunk = chunk,
				Some(Err(_)) => return Poll::Ready(Err(io::Error::other("bucket object not read whole"))),
				None => return Poll::Ready(Ok(())),
			}
		}
	}
}

/// HTTPS downloads, a redirect followed to HTTPS alone.
#[derive(Debug, Default)]
pub struct Https;

impl Download for Https {
	async fn download(&self, url: &str) -> Result<Vec<u8>, BucketError> {
		static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
		let client = match CLIENT.get() {
			Some(client) => client.clone(),
			None => {
				let client = download_client(true)?;
				CLIENT.get_or_init(|| client).clone()
			}
		};
		fetch(&client, url).await
	}
}

/// A client following up to ten redirects, each to HTTPS alone, as `curl --proto-redir =https`.
fn download_client(https_only: bool) -> Result<reqwest::Client, BucketError> {
	crate::tls::install();
	let policy = Policy::custom(|attempt| {
		if attempt.url().scheme() == "https" {
			Policy::limited(10).redirect(attempt)
		} else {
			attempt.error("redirect to another scheme than HTTPS")
		}
	});
	reqwest::Client::builder()
		.https_only(https_only)
		.redirect(policy)
		.build()
		.map_err(|_| BucketError::Transport)
}

/// Reads a download whole, any status but 200 refused.
async fn fetch(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, BucketError> {
	let response = client.get(url).send().await.map_err(|_| BucketError::Transport)?;
	match response.status().as_u16() {
		200 => Ok(response.bytes().await.map_err(|_| BucketError::Transport)?.to_vec()),
		code => Err(BucketError::Status(code)),
	}
}

#[cfg(test)]
mod tests {
	use tokio::io::{AsyncReadExt, AsyncWriteExt};
	use tokio::net::TcpListener;

	use super::*;

	fn pair() -> Credentials {
		Credentials { key: "AKID0123".into(), secret: "se/cr+et=".into() }
	}

	/// Serves each canned answer in turn on localhost, the answers written knowing its origin.
	async fn serve(answers: impl FnOnce(&str) -> Vec<String>) -> String {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let origin = format!("http://{}", listener.local_addr().unwrap());
		let answers = answers(&origin);
		tokio::spawn(async move {
			for answer in answers {
				let (mut socket, _) = listener.accept().await.unwrap();
				let mut request = Vec::new();
				let mut buf = [0u8; 1024];
				while !request.windows(4).any(|w| w == b"\r\n\r\n") {
					let n = socket.read(&mut buf).await.unwrap();
					if n == 0 {
						break;
					}
					request.extend_from_slice(&buf[..n]);
				}
				socket.write_all(answer.as_bytes()).await.unwrap();
				socket.shutdown().await.unwrap();
			}
		});
		origin
	}

	fn answer(status: &str, headers: &str, body: &str) -> String {
		format!(
			"HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n{headers}\r\n{body}",
			body.len()
		)
	}

	#[test]
	fn signed_url_is_path_style_sigv4_for_auto() {
		let remote = Remote::new("systems", "https://r2.example.com:8443/", pair()).unwrap();
		let url = remote.signed("nar/abc.nar.zst").unwrap().unwrap();
		assert_eq!(url.scheme(), "https");
		assert_eq!(url.host_str(), Some("r2.example.com"));
		assert_eq!(url.port(), Some(8443));
		assert_eq!(url.path(), "/systems/nar/abc.nar.zst");
		let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
		assert_eq!(query["X-Amz-Algorithm"], "AWS4-HMAC-SHA256");
		let credential: Vec<&str> = query["X-Amz-Credential"].split('/').collect();
		assert_eq!(credential.len(), 5);
		assert_eq!(credential[0], "AKID0123");
		assert_eq!(&credential[2..], ["auto", "s3", "aws4_request"]);
		assert_eq!(query["X-Amz-SignedHeaders"], "host");
		assert_eq!(query["X-Amz-Expires"], "300");
		let signature = &query["X-Amz-Signature"];
		assert_eq!(signature.len(), 64);
		assert!(signature.bytes().all(|b| b.is_ascii_hexdigit()));
		assert!(!url.as_str().contains("se/cr+et=") && !url.as_str().contains("se%2Fcr%2Bet%3D"));
	}

	#[test]
	fn directory_signs_nothing() {
		let remote = Remote::new("file:///srv/bucket", "", pair()).unwrap();
		assert!(remote.signed("x").unwrap().is_none());
	}

	#[tokio::test]
	async fn request_maps_each_status() {
		crate::tls::install();
		let origin = serve(|_| {
			vec![
				answer("200 OK", "", "object"),
				answer("404 Not Found", "", ""),
				answer("403 Forbidden", "", "denied"),
				answer("301 Moved Permanently", "location: /elsewhere\r\n", ""),
			]
		})
		.await;
		let client = s3_client().unwrap();
		let url = |path: &str| Url::parse(&format!("{origin}/{path}")).unwrap();
		let body = request(&client, url("a")).await.unwrap().unwrap().bytes().await.unwrap();
		assert_eq!(&body[..], b"object");
		assert!(request(&client, url("b")).await.unwrap().is_none());
		assert!(matches!(request(&client, url("c")).await, Err(BucketError::Status(403))));
		assert!(matches!(request(&client, url("d")).await, Err(BucketError::Status(301))));
	}

	#[tokio::test]
	async fn unreachable_bucket_is_transport() {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let origin = format!("http://{}", listener.local_addr().unwrap());
		drop(listener);
		let client = s3_client().unwrap();
		let result = request(&client, Url::parse(&format!("{origin}/a")).unwrap()).await;
		assert!(matches!(result, Err(BucketError::Transport)));
	}

	#[tokio::test]
	async fn broken_body_is_an_error() {
		let origin =
			serve(|_| vec!["HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort".into()]).await;
		let client = s3_client().unwrap();
		let response =
			request(&client, Url::parse(&format!("{origin}/a")).unwrap()).await.unwrap().unwrap();
		let mut body = Body { stream: response.bytes_stream().boxed(), chunk: Bytes::new() };
		let mut read = Vec::new();
		let error = body.read_to_end(&mut read).await.unwrap_err();
		assert_eq!(error.to_string(), "bucket object not read whole");
	}

	#[tokio::test]
	async fn download_refuses_plain_http_and_redirects_to_it() {
		assert!(matches!(
			Https.download("http://127.0.0.1:9/archive").await,
			Err(BucketError::Transport)
		));
		// A followed redirect would take the 404 meant for the second request.
		let origin = serve(|origin| {
			vec![
				answer("302 Found", &format!("location: {origin}/plain\r\n"), ""),
				answer("404 Not Found", "", ""),
				answer("200 OK", "", "archive"),
			]
		})
		.await;
		let client = download_client(false).unwrap();
		assert!(matches!(fetch(&client, &format!("{origin}/a")).await, Err(BucketError::Transport)));
		assert!(matches!(fetch(&client, &format!("{origin}/b")).await, Err(BucketError::Status(404))));
		assert_eq!(fetch(&client, &format!("{origin}/c")).await.unwrap(), b"archive");
	}

	#[tokio::test]
	async fn directory_reads_and_misses() {
		let dir = tempfile::tempdir().unwrap();
		std::fs::create_dir(dir.path().join("pointer")).unwrap();
		std::fs::write(dir.path().join("pointer/a"), b"pointer").unwrap();
		let remote = Remote::new(&format!("file://{}", dir.path().display()), "", pair()).unwrap();
		assert_eq!(remote.get("pointer/a").await.unwrap().unwrap(), b"pointer");
		assert!(remote.get("pointer/b").await.unwrap().is_none());
		assert!(matches!(remote.get("pointer").await, Err(BucketError::Transport)));
		let mut object = remote.open("pointer/a").await.unwrap().unwrap();
		let mut read = Vec::new();
		object.read_to_end(&mut read).await.unwrap();
		assert_eq!(read, b"pointer");
		assert!(remote.open("pointer/b").await.unwrap().is_none());
	}
}
