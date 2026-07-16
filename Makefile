# SAM Configuration
SAM_STACK_NAME = Maxi80Backend-2025

# API Configuration
AWS_REGION = eu-central-1
AWS_PROFILE = maxi80

format:
	swift format -i -r Package.swift Sources Tests

build:
	swift package --disable-sandbox --allow-network-connections docker lambda-build --cross-compile container --disable-docker-image-update --base-docker-image swift:amazonlinux2023 --products IcecastMetadataCollector --products Maxi80Lambda --products AuthorizerLambda
	
test:
	swift test

deploy:
	sam deploy --config-env dev --express

# Get the HTTP API URL and API key from AWS
API_GATEWAY_URL = $(shell aws cloudformation describe-stacks --stack-name $(SAM_STACK_NAME) --region $(AWS_REGION) --profile $(AWS_PROFILE) --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text 2>/dev/null)
API_KEY = $(shell aws ssm get-parameter --name /maxi80/api-key --with-decryption --region $(AWS_REGION) --profile $(AWS_PROFILE) --query 'Parameter.Value' --output text 2>/dev/null | tr -d '"')

call-station:
	@curl -s -X GET \
  "$(API_GATEWAY_URL)station" \
  -H "Authorization: $(API_KEY)" \
  -H "Accept: application/json"

call-artwork:
	@curl -s -X GET \
  "$(API_GATEWAY_URL)artwork?artist=Pink%20Floyd&title=The%20Wall" \
  -H "Authorization: $(API_KEY)" \
  -H "Accept: application/json"

call-history:
	@curl -s -X GET \
  "$(API_GATEWAY_URL)history" \
  -H "Authorization: $(API_KEY)" \
  -H "Accept: application/json"

call-unauthorized:
	@curl -s -X GET \
  "$(API_GATEWAY_URL)station" \
  -H "Authorization: wrong-key" \
  -H "Accept: application/json"

STREAM_URL = https://audio1.maxi80.com

# Print the current ICY StreamTitle from the live stream. Useful to check whether
# the broadcaster is sending real track metadata or only the default filler title.
stream-metadata:
	@scripts/stream-metadata.sh $(STREAM_URL)

logs-maxi80:
	sam logs --stack-name $(SAM_STACK_NAME) --name Maxi80Lambda --region $(AWS_REGION) --profile $(AWS_PROFILE) --tail

logs-collector:
	sam logs --stack-name $(SAM_STACK_NAME) --name IcecastMetadataCollector --region $(AWS_REGION) --profile $(AWS_PROFILE) --tail

logs-authorizer:
	sam logs --stack-name $(SAM_STACK_NAME) --name AuthorizerLambda --region $(AWS_REGION) --profile $(AWS_PROFILE) --tail

get-parameters:
	@aws ssm get-parameters-by-path --path /maxi80/ --with-decryption --region $(AWS_REGION) --profile $(AWS_PROFILE) --query 'Parameters[*].[Name,Value]'
