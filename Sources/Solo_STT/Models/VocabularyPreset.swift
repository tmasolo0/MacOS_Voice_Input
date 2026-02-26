import Foundation

enum VocabularyPreset: String, CaseIterable, Identifiable {
    case it = "it"
    case design = "design"
    case business = "business"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .it: return "IT / Разработка"
        case .design: return "Дизайн"
        case .business: return "Бизнес"
        }
    }

    var description: String {
        switch self {
        case .it: return "Git, Docker, API, AI/ML, LLM, фреймворки и DevOps"
        case .design: return "Figma, UI/UX, типографика, компоненты, анимация"
        case .business: return "Agile, метрики, финансы, маркетинг, инвестиции"
        }
    }

    var terms: String {
        switch self {
        case .it:
            return [
                // Git & DevOps
                "git, коммит, репозиторий, бранч, ребейз, чери-пик, мёрж, пулл-реквест, код-ревью, хотфикс",
                "деплой, продакшн, стейджинг, CI/CD, Docker, Kubernetes, Nginx, Terraform, Jenkins",
                // Языки & фреймворки
                "Python, TypeScript, JavaScript, Swift, Kotlin, Golang, Rust, Java, C++",
                "React, Vue, Next.js, Node.js, Django, FastAPI, Flutter, SwiftUI",
                // Инфраструктура
                "API, REST, GraphQL, WebSocket, эндпоинт, микросервис, бэкенд, фронтенд",
                "Redis, PostgreSQL, MongoDB, SQL, NoSQL, миграция, индекс, ORM",
                "AWS, S3, CDN, SSL, DNS, SSH, Docker, контейнер",
                // Разработка
                "рефакторинг, дебаг, баг, логи, стектрейс, линтер, SDK, CLI, IDE, npm, webpack",
                "JSON, YAML, фреймворк, библиотека, пакет, зависимость, сборка, билд",
                // AI / ML / LLM
                "нейросеть, модель, промпт, токен, эмбеддинг, файн-тюнинг, инференс, трансформер",
                "GPT, Claude, LLM, RAG, контекстное окно, галлюцинация, температура, сэмплинг",
                "датасет, обучение, дообучение, предобучение, RLHF, LoRA, квантизация, GGUF, GGML",
                "Whisper, диффузия, Stable Diffusion, Midjourney, TensorFlow, PyTorch, Hugging Face",
                "вектор, векторная база, чанк, пайплайн, агент, мультимодальный",
                "Ollama, llama.cpp, CUDA, GPU, VRAM, бэтч, лейтенси",
            ].joined(separator: ", ")
        case .design:
            return [
                // Инструменты
                "Figma, Sketch, Photoshop, Illustrator, After Effects, Blender, Canva, Framer",
                // UI элементы
                "UI, UX, макет, прототип, wireframe, компонент, дизайн-система",
                "модалка, дропдаун, тогл, тултип, табы, аккордеон, карточка",
                "хедер, футер, сайдбар, навбар, breadcrumbs",
                // UX
                "юзабилити, персона, customer journey, user flow, A/B-тест, тепловая карта, юзер-ресёрч",
                // Типографика & визуал
                "типографика, шрифт, кернинг, интерлиньяж, контраст, ретина",
                "градиент, SVG, растр, вектор, иконка, цветовая палитра",
                // Концепции
                "брендбук, мудборд, стайлгайд, гайдлайн, грид, лейаут, адаптив, респонсив",
                "hover, анимация, микроинтеракция, motion design, переход, сторибоард",
            ].joined(separator: ", ")
        case .business:
            return [
                // Agile & управление
                "спринт, бэклог, скрам, канбан, стендап, ретро, ретроспектива",
                "эпик, юзер-стори, стори-поинт, велосити, инкремент, бёрндаун",
                "стейкхолдер, дедлайн, роадмап, MVP, тимлид, тех-лид",
                // Метрики & финансы
                "KPI, OKR, метрика, конверсия, воронка, юнит-экономика",
                "LTV, CAC, ARPU, MRR, ARR, churn, retention, когорта",
                "P&L, EBITDA, маржа, выручка, ROI, ROAS",
                // Стратегия
                "pivot, product-market fit, go-to-market, B2B, B2C, SaaS, скейлинг",
                "онбординг, перформанс-ревью, фидбэк",
                // Инвестиции
                "раунд, seed, Series A, валюация, венчур, питч, трекшн",
                // Маркетинг
                "SEO, CRM, таргетинг, лид, лидогенерация, CTR, ребрендинг",
            ].joined(separator: ", ")
        }
    }
}
