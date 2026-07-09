# Установка и использование — русский

Проверка:

```bash
bash scripts/bash/validate-package.sh
```

Внедрение в существующий проект:

```bash
bash scripts/bash/adopt-pipeline.sh "/path/to/existing/project"
```

Публикация на GitHub:

```bash
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline"
git branch -M main
git remote add origin https://github.com/<OWNER>/<REPO>.git
git push -u origin main
```
