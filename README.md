# Text Extract - Quickstart

## Deploy
```bash
cd infra/terraform
terraform init
terraform apply -auto-approve
```

Test:
IMG=path/to/image.png
curl -s -X POST "$EXTRACT_URL" -H "Content-Type: image/png" --data-binary "@$IMG" | jq
curl -s -X POST "$EXTRACT_BEST_URL" -H "Content-Type: image/png" --data-binary "@$IMG" | jq

Notes:
- Supported formats: PNG/JPEG (single page).