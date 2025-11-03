# quic-host

A container-based web service that uses QUIC (HTTP/3) to deliver web page content and stream video files. This service automatically supports protocol fallback from HTTP/3 to HTTP/2 and HTTP/1.1, behaving like a typical public website.

## Features

- **HTTP/3 (QUIC) Support**: Modern protocol using UDP for improved performance
- **Automatic Fallback**: Graceful degradation to HTTP/2 and HTTP/1.1 when QUIC is unavailable
- **Web Content Delivery**: Serves a sample HTML page demonstrating QUIC capabilities
- **Video Streaming**: Includes a sample video file streamed over QUIC
- **Container-Based**: Easy deployment using Docker
- **Self-Signed Certificates**: Automatic generation for testing (use proper certificates in production)

## Quick Start

### Using Docker

Build the container:
```bash
docker build -t quic-host .
```

Run the container:
```bash
docker run -p 8443:8443 quic-host
```

Access the service:
- Open your browser to `https://localhost:8443`
- Accept the self-signed certificate warning (for testing)

### Building from Source

Prerequisites:
- Go 1.21 or later

Build and run:
```bash
go mod download
go build -o quic-host main.go
./quic-host
```

## Usage

### Environment Variables

- `PORT`: Server port (default: 8443)
- `TLS_CERT_FILE`: Path to TLS certificate file (optional, generates self-signed if not provided)
- `TLS_KEY_FILE`: Path to TLS private key file (optional, generates self-signed if not provided)

Example with custom port:
```bash
docker run -e PORT=9443 -p 9443:9443 quic-host
```

Example with custom certificates:
```bash
docker run -v /path/to/certs:/certs \
  -e TLS_CERT_FILE=/certs/cert.pem \
  -e TLS_KEY_FILE=/certs/key.pem \
  -p 8443:8443 quic-host
```

## Testing QUIC Support

### Automated Test Script

Run the included test script to validate both test scenarios:

```bash
# Start the service
docker run -d --name quic-host -p 8443:8443 quic-host

# Run the test script
./test.sh
```

The test script validates:
- Web page content delivery over QUIC
- Video streaming functionality
- Protocol fallback behavior (HTTP/3 → HTTP/2 → HTTP/1.1)

### Using Chrome/Chromium

1. Open Chrome DevTools (F12)
2. Go to the Network tab
3. Access `https://localhost:8443`
4. Check the Protocol column - it should show `h3` for HTTP/3

### Using curl (with HTTP/3 support)

```bash
# If you have curl with HTTP/3 support
curl --http3 https://localhost:8443 -k
```

### Protocol Detection

The web page includes JavaScript that automatically detects and displays the protocol being used (HTTP/3, HTTP/2, or HTTP/1.1).

## Test Scenarios

### Scenario 1: Web Page Content Delivery

Navigate to `https://localhost:8443/` to see the main page delivered over QUIC. The page includes:
- Protocol information and detection
- QUIC feature description
- Connection details

### Scenario 2: Video Streaming

The main page includes an embedded video player that streams a sample video file over QUIC. You can also access the video directly at:
- `https://localhost:8443/sample-video.mp4`

## Architecture

The service runs two servers simultaneously:
1. **HTTP/3 (QUIC) Server**: Primary server using UDP
2. **HTTP/2/HTTP/1.1 Fallback Server**: Backup server using TCP

Browsers automatically negotiate the best available protocol:
- Modern browsers with QUIC support → HTTP/3
- Browsers without QUIC but with HTTP/2 → HTTP/2
- Older browsers → HTTP/1.1

## Security Notes

⚠️ **Important**: This implementation uses self-signed certificates for testing purposes. For production use:

1. Obtain proper TLS certificates from a Certificate Authority
2. Mount certificates into the container
3. Set `TLS_CERT_FILE` and `TLS_KEY_FILE` environment variables

## Development

Project structure:
```
quic-host/
├── main.go           # Main server implementation
├── static/           # Static web content
│   ├── index.html    # Demo web page
│   └── sample-video.mp4  # Sample video file
├── Dockerfile        # Container build configuration
├── go.mod           # Go module dependencies
└── README.md        # This file
```

## Troubleshooting

**Browser doesn't show HTTP/3**:
- Ensure you're using a modern browser (Chrome 87+, Firefox 88+, Safari 14+)
- Check browser flags for QUIC/HTTP3 support
- Verify the port is accessible and not blocked by firewall

**Certificate errors**:
- Accept the self-signed certificate in your browser
- For production, use proper certificates

**Container build fails**:
- Ensure Docker is installed and running
- Check Go version compatibility (1.21+)

## License

MIT License - feel free to use this for testing and development purposes.

