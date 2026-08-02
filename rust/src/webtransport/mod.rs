use cfg_if::cfg_if;

cfg_if! {
    if #[cfg(wasm)] {
        /// flutter_rust_bridge:ignore
        pub mod wasm;
    }
}

use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;
use bytes::Bytes;
pub use web_transport::CongestionControl;

cfg_if! {
    if #[cfg(wasm)] {
        /// flutter_rust_bridge:ignore
        mod wt {
            pub use super::wasm::{
                ClientBuilder,
                stream::recv::RecvStream,
                stream::send::SendStream,
                session::Session,
            };
        }
    } else {
        /// flutter_rust_bridge:ignore
        mod wt {
            pub use web_transport::*;
        }
    }
}

use wt::{ClientBuilder, Session, SendStream, RecvStream};

#[frb(mirror(CongestionControl))]
pub enum _CongestionControl {
    Default,
    Throughput,
    LowLatency,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("The input data `{}` has invalid syntax: {}", .by, .reason)]
    Syntax { by: String, reason: String },

    #[error("Cannot init trusted certificates configuration: {}", .reason)]
    TrustedCerts { reason: String },

    #[error("Failed to connect: {}", .reason)]
    Connect { reason: String },

    #[error("Failed to accept/open stream: {}", .reason)]
    OpeningStream { reason: String },

    #[error("Failed to operate stream: {}", .reason)]
    Stream { reason: String },

    #[error("Failed to handle datagram: {}", .reason)]
    Datagram { reason: String },

    #[error("The session closed: {}", .0)]
    Close(String)
}

#[derive(Default)]
pub struct WebTransportOptions {
    pub congestion_control: Option<CongestionControl>,
    pub server_certificate_hashes: Option<Vec<Vec<u8>>>,
    pub protocols: Option<Vec<String>>,
}

#[frb(opaque)]
pub struct WebTransport {
    session: Session
}

impl WebTransport {
    #[frb(positional)]
    pub async fn connect(url: &str, options: Option<WebTransportOptions>) -> Result<Self, Error> {
        let url = url::Url::parse(url)
            .map_err(|e| Error::Syntax { by: url.to_string(), reason: e.to_string() })?;
        let options = options.unwrap_or_default();
        let client = ClientBuilder::default();
        // Apply `protocols`
        let client = if let Some(protocols) = options.protocols {
            client.with_protocols(protocols)
        } else {
            client
        };
        // Apply `congestion_control`
        let client = if let Some(cc) = options.congestion_control {
            client.with_congestion_control(cc)
        } else {
            client
        };
        // Apply `server_certificate_hashes`
        let client = if let Some(hashes) = options.server_certificate_hashes {
            client.with_server_certificate_hashes(hashes)
        } else {
            client.with_system_roots()
        };
        // In native-side, it is Result
        #[cfg(not(wasm))]
        let client = client.map_err(|e| Error::TrustedCerts { reason: e.to_string() })?;

        let session = client.connect(url).await
            .map_err(|e| Error::TrustedCerts { reason: e.to_string() })?;
        Ok(Self { session })
    }

    pub async fn open_uni(&self) -> Result<WritableStream, Error> {
        self.session.open_uni().await
            .map_err(|e| Error::OpeningStream { reason: e.to_string() })
            .map(|tx| WritableStream(tx))
    }

    pub async fn open_bi(&self) -> Result<(WritableStream, ReadableStream), Error> {
        self.session.open_bi().await
            .map_err(|e| Error::OpeningStream { reason: e.to_string() })
            .map(|(tx, rx)| (WritableStream(tx), ReadableStream(rx)))
    }

    pub async fn accept_uni(&self) -> Result<ReadableStream, Error> {
        self.session.accept_uni().await
            .map_err(|e| Error::OpeningStream { reason: e.to_string() })
            .map(|rx| ReadableStream(rx))
    }
    
    pub async fn accept_bi(&self) -> Result<(WritableStream, ReadableStream), Error> {
        self.session.accept_bi().await
            .map_err(|e| Error::OpeningStream { reason: e.to_string() })
            .map(|(tx, rx)| (WritableStream(tx), ReadableStream(rx)))
    }

    #[frb(type_64bit_int)]
    pub async fn max_datagram_size(&self) -> usize {
        self.session.max_datagram_size().await
    }

    pub async fn recv_datagram(&self) -> Result<Vec<u8>, Error> {
        self.session.recv_datagram()
            .await
            .map_err(|e| Error::Datagram { reason: e.to_string() })
            .map(|bytes| bytes.into())
    }

    #[frb(positional)]
    pub async fn send_datagram(&self, payload: &[u8]) -> Result<(), Error> {
        self.session.send_datagram(Bytes::copy_from_slice(payload))
            .await
            .map_err(|e| Error::Datagram { reason: e.to_string() })
    }

    #[frb(sync, positional)]
    pub fn close(&self, code: u32, reason: &str) {
        self.session.close(code, reason);
    }

    #[frb(getter)]
    pub async fn closed(&self) -> Error {
        Error::Close(self.session.closed().await.to_string())
    }

    #[frb(sync, getter)]
    pub fn url(&self) -> String {
        self.session.url().to_string()
    }

    #[frb(sync, getter)]
    pub fn protocol(&self) -> Option<String> {
        self.session.protocol().map(|s| s.to_string())
    }
}

#[frb(opaque)]
pub struct WritableStream(SendStream);

impl WritableStream {
    #[frb(positional, type_64bit_int)]
    pub async fn write(&mut self, buf: &[u8]) -> Result<usize, Error> {
        let result = self.0.write(buf).await
            .map_err(|e| Error::Stream { reason: e.to_string() });
        cfg_if! {
            if #[cfg(wasm)] {
                let _ = result;
                Ok(buf.len())
            } else {
                result
            }
        }
    }

    #[frb(positional)]
    pub async fn write_all(&mut self, buf: &[u8]) -> Result<(), Error> {
        let mut offset = 0;
        while offset < buf.len() {
            offset += self.write(&buf[offset..]).await?;
        }
        Ok(())
    }

    #[frb(sync, setter, positional)]
    pub fn set_priority(&mut self, order: i32) {
        self.0.set_priority(order);
    }

    #[frb(sync, positional)]
    pub fn reset(&mut self, code: u32) {
        cfg_if! {
            if #[cfg(wasm)] {
                let msg = format!("Code: {}", code);
                self.0.reset(&msg);
            } else {
                self.0.reset(code);
            }
        }
    }

    #[frb(sync)]
    pub fn finish(&mut self) -> Result<(), Error> {
        self.0.finish()
            .map_err(|e| Error::Stream { reason: e.to_string() })
    }

    pub async fn closed(&mut self) -> Result<Option<u8>, Error> {
        self.0.closed().await
            .map_err(|e| Error::Stream { reason: e.to_string() })
    }
}

#[frb(opaque)]
pub struct ReadableStream(RecvStream);

impl ReadableStream {
    #[frb(type_64bit_int)]
    pub async fn read(
        &mut self,
        #[frb(default = 8192)]
        max: usize
    ) -> Result<Option<Vec<u8>>, Error> {
        self.0.read(max).await
            .map_err(|e| Error::Stream { reason: e.to_string() })
            .map(|option| option.map(|bytes| bytes.into()))
    }

    #[frb(type_64bit_int)]
    pub async fn reader(
        &mut self,
        #[frb(default = 8192)]
        max: usize,
        sink: StreamSink<Vec<u8>>
    ) {
        loop {
            let get_error = match self.read(max).await {
                Ok(Some(bytes)) => {
                    sink.add(bytes).is_err()
                },
                Ok(None) => {
                    break;
                },
                Err(err) => {
                    sink.add_error(err).is_err()
                },
            };

            if get_error {
                break
            }
        }
    }

    #[frb(sync, positional)]
    pub fn stop(&mut self, code: u32) {
        cfg_if! {
            if #[cfg(wasm)] {
                let msg = format!("Code: {}", code);
                self.0.stop(&msg);
            } else {
                self.0.stop(code);
            }
        }
    }

    pub async fn closed(&mut self) -> Result<Option<u8>, Error> {
        self.0.closed().await
            .map_err(|e| Error::Stream { reason: e.to_string() })
    }
}