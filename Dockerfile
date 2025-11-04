# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copy go module files and source
COPY go.mod go.sum ./
COPY main.go ./
COPY static/ ./static/

# Build the application (Go will download dependencies automatically)
RUN go build -o quic-host main.go

# Runtime stage - use minimal golang image
FROM golang:1.21-alpine

WORKDIR /app

# Copy binary from builder (static files are embedded in the binary)
COPY --from=builder /app/quic-host .

# Expose port 8443 (HTTPS/QUIC)
EXPOSE 8443

# Run the application
CMD ["./quic-host"]
