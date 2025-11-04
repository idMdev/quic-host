# Build stage
FROM golang:1.21-alpine AS builder

# Install ca-certificates and update them
RUN apk add --no-cache ca-certificates && update-ca-certificates

WORKDIR /app

# Copy go module files first for better caching
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code and static files
COPY main.go ./
COPY static/ ./static/

# Build the application
RUN CGO_ENABLED=0 go build -o quic-host main.go

# Runtime stage - use minimal alpine image
FROM alpine:latest

# Install ca-certificates for HTTPS
RUN apk add --no-cache ca-certificates

WORKDIR /app

# Copy binary from builder (static files are embedded in the binary)
COPY --from=builder /app/quic-host .

# Expose port 8443 (HTTPS/QUIC)
EXPOSE 8443/tcp
EXPOSE 8443/udp

# Run the application
CMD ["./quic-host"]
