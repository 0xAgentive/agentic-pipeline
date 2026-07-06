# Публикация на GitHub

```bash
bash scripts/bash/validate-package.sh
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline"
git branch -M main
git remote add origin https://github.com/<OWNER>/<REPO>.git
git push -u origin main
```

Перед публикацией проверь `LICENSE`, `SECURITY.md`, отсутствие приватных путей, логов и секретов.
