.PHONY: install test run serve version docker-build docker-run docker-run-http \
        compose-up compose-down compose-logs compose-ps clean

install:
	bundle install

test:
	bundle exec rake test

run:
	bundle exec bookworm-mcp

serve:
	bundle exec bookworm-mcp --http

version:
	bundle exec bookworm-mcp --version

docker-build:
	docker build -t bookworm-mcp .

docker-run:
	docker run --rm -i bookworm-mcp

docker-run-http:
	docker run --rm -p 9292:9292 -p 9443:9443 bookworm-mcp --http --host 0.0.0.0

compose-up:
	docker compose up --build -d --wait

compose-down:
	docker compose down

compose-logs:
	docker compose logs -f --tail=100

compose-ps:
	docker compose ps

clean:
	rm -rf pkg tmp coverage
