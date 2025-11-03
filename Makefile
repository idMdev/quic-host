.PHONY: build run stop clean test docker-build docker-run docker-stop help

help:
	@echo "Available targets:"
	@echo "  build          - Build the Go binary"
	@echo "  run            - Run the service locally"
	@echo "  test           - Test the service"
	@echo "  clean          - Clean build artifacts"
	@echo "  docker-build   - Build Docker image"
	@echo "  docker-run     - Run Docker container"
	@echo "  docker-stop    - Stop Docker container"
	@echo "  docker-compose - Run with docker-compose"

build:
	go build -o quic-host main.go

run:
	./quic-host

test:
	@echo "Testing HTTP/2 endpoint..."
	@curl -k -s -o /dev/null -w "HTTP Status: %{http_code}\n" https://localhost:8443
	@echo "Testing video endpoint..."
	@curl -k -s -o /dev/null -w "HTTP Status: %{http_code}\n" https://localhost:8443/sample-video.mp4

clean:
	rm -f quic-host

docker-build:
	docker build -t quic-host .

docker-run:
	docker run -d --name quic-host -p 8443:8443 quic-host

docker-stop:
	docker stop quic-host && docker rm quic-host

docker-compose:
	docker-compose up -d
