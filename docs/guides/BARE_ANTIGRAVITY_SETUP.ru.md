# 🚀 Развёртывание Agentic Pipeline на «голом» Antigravity за 3 шага

> **Пошаговое руководство для быстрого старта с нуля**  
> Время установки: **2 минуты** | Требования: Antigravity IDE, PowerShell 7+, Node.js 18+, Git

---

## ⚡ Экспресс-установка (3 команды)

### Шаг 1. Клонируйте репозиторий
Откройте PowerShell (или терминал) и склонируйте репозиторий фреймворка в удобную папку:

```powershell
cd "$env:USERPROFILE\Documents\antigravity"
git clone https://github.com/0xAgentive/agentic-pipeline.git
cd agentic-pipeline
```

---

### Шаг 2. Установите глобальные скиллы Antigravity в 1 клик
Запустите скрипт автоматической установки:

```powershell
& pwsh -NoProfile -ExecutionPolicy Bypass -File "./scripts/windows/Install-GlobalSkills.ps1"
```

*Что произойдёт автоматически:*  
Скрипт скопирует все 6 глобальных скиллов (`agentic-project-scaffold`, `companion-project-context-pack`, `local-artifact-delivery`, `quota-safe-continuity`, `stitch-design-sync`, `mcp-tooling-discipline`) в системный каталог Antigravity (`~/.gemini/config/skills/`). Они сразу станут доступны во всех ваших окнах и проектах!

---

### Шаг 3. Создайте свой первый проект под пайплайном!
Откройте Antigravity, начните новый диалог с агентом и напишите:

```text
/new-project MyAwesomeProject
```

*Готово!* Агент за 10 секунд:
1. Создаст репозиторий `C:\Users\<Вы>\Documents\antigravity\MyAwesomeProject`;
2. Накатит стандарты качества v1.2.27, правила безопасности и научный брандмауэр;
3. Зарегистрирует проект в фоновом Action Bridge;
4. **Сгенерирует готовый архив `MYAWESOMEPROJECT_COMPREHENSIVE_COMPANION_PACK.zip` для загрузки в ChatGPT / Claude.**

---

## 🔄 Как подключить СУЩЕСТВУЮЩИЙ проект (Onboarding / Adopt)

Если у вас уже есть написанный проект на Python, React, Rust, Go или C#, и вы хотите перевести его на рельсы Handoff-разработки:

Просто напишите в чате Antigravity:
```text
/adopt-project C:\путь\к\вашему\репозиторию
```

Пайплайн аккуратно добавит управляющий слой `.agents/` и `.agy/`, **не трогая и не изменяя ни единого файла вашего существующего кода**, и сразу соберет архив для ChatGPT.

---

## 🧭 Как работать в парадигме Handoff-Driven Development

```text
1. Соберите контекст кодовой базы:     /companion-pack
2. Отдайте ZIP в ChatGPT / Claude:    Компаньон спроектирует ТЗ и выдаст Action Packet
3. Скачайте файл из браузера:         Action Bridge за 250 мс перенесёт его в проект
4. Дайте отмашку Antigravity:         /nextphase (или /nextphase /goal)
5. Получите результат:                4 понятных пункта отчёта + LATEST_CONTEXT.zip
```

---

*Справка по всем командам: [Атлас Команд и Скиллов](../reference/COMMANDS_AND_SKILLS_DIRECTORY.md)*
