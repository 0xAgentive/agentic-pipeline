# Installation and Usage — English

Validate:

```bash
bash scripts/bash/validate-package.sh
```

Adopt into an existing project:

```bash
bash scripts/bash/adopt-pipeline.sh "/path/to/existing/project"
```

Publish to GitHub:

```bash
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline"
git branch -M main
git remote add origin https://github.com/<OWNER>/<REPO>.git
git push -u origin main
```
