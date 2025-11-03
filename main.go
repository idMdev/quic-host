package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"embed"
	"encoding/pem"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

//go:embed static/*
var staticFiles embed.FS

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8443"
	}

	// Setup TLS configuration
	tlsConfig, err := generateTLSConfig()
	if err != nil {
		log.Fatal("Failed to generate TLS config:", err)
	}

	// Create HTTP handler
	mux := http.NewServeMux()
	
	// Serve static files (HTML, CSS, JS)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Request: %s %s (Protocol: %s)", r.Method, r.URL.Path, r.Proto)
		
		path := r.URL.Path
		if path == "/" {
			path = "/index.html"
		}
		
		content, err := staticFiles.ReadFile("static" + path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		
		// Set content type based on file extension
		contentType := getContentType(path)
		w.Header().Set("Content-Type", contentType)
		
		// Enable streaming for video files
		if contentType == "video/mp4" {
			w.Header().Set("Accept-Ranges", "bytes")
		}
		
		w.WriteHeader(http.StatusOK)
		w.Write(content)
	})

	// Start HTTP/3 (QUIC) server
	go func() {
		server := &http3.Server{
			Addr:      ":" + port,
			Handler:   mux,
			TLSConfig: tlsConfig,
			QuicConfig: &quic.Config{
				EnableDatagrams: true,
			},
		}
		
		log.Printf("Starting HTTP/3 (QUIC) server on port %s", port)
		if err := server.ListenAndServe(); err != nil {
			log.Fatal("HTTP/3 server error:", err)
		}
	}()

	// Start HTTP/2 and HTTP/1.1 fallback server
	fallbackServer := &http.Server{
		Addr:      ":" + port,
		Handler:   mux,
		TLSConfig: tlsConfig,
	}
	
	log.Printf("Starting HTTP/2 and HTTP/1.1 fallback server on port %s", port)
	if err := fallbackServer.ListenAndServeTLS("", ""); err != nil {
		log.Fatal("Fallback server error:", err)
	}
}

func generateTLSConfig() (*tls.Config, error) {
	// Check if certificate files exist
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	
	if certFile == "" {
		certFile = "/certs/cert.pem"
	}
	if keyFile == "" {
		keyFile = "/certs/key.pem"
	}

	// Try to load existing certificates
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		// If certificates don't exist, generate self-signed ones
		log.Println("Using self-signed certificate (for testing only)")
		cert, err = generateSelfSignedCert()
		if err != nil {
			return nil, err
		}
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"h3", "h2", "http/1.1"}, // HTTP/3, HTTP/2, HTTP/1.1
		MinVersion:   tls.VersionTLS12,
	}, nil
}

func generateSelfSignedCert() (tls.Certificate, error) {
	certPEM, keyPEM, err := generateSelfSignedCertPEM()
	if err != nil {
		return tls.Certificate{}, err
	}
	
	return tls.X509KeyPair(certPEM, keyPEM)
}

func generateSelfSignedCertPEM() ([]byte, []byte, error) {
	// Generate a new private key
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	// Create certificate template
	notBefore := time.Now()
	notAfter := notBefore.Add(365 * 24 * time.Hour) // Valid for 1 year

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"QUIC Test Server"},
			CommonName:   "localhost",
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	// Create self-signed certificate
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, nil, err
	}

	// Encode certificate to PEM
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})

	// Encode private key to PEM
	privBytes, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privBytes})

	return certPEM, keyPEM, nil
}

func getContentType(path string) string {
	ext := filepath.Ext(path)
	switch ext {
	case ".html":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "application/javascript; charset=utf-8"
	case ".mp4":
		return "video/mp4"
	case ".json":
		return "application/json; charset=utf-8"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	default:
		return "application/octet-stream"
	}
}
