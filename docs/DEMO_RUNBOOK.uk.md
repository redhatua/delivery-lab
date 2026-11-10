# Сценарій демонстрації (10 хвилин)

Усі команди нижче виконувались у цьому стенді 10 листопада 2026. Вивід скорочено, значення
UID і digest у вас будуть інші. Облікові дані тут не наведені: вони в `.lab/secrets/`.

## Перед співбесідою

1. `make doctor` і `make status`: обидві VM running, agent online, app Synced/Healthy.
2. Відкрийте вкладки: Jenkins http://192.168.77.10:8080 (admin), Gitea http://192.168.77.10:3000 (lab),
   Argo CD http://127.0.0.1:8443 (запустити `make argo-ui` в окремому терміналі).
3. Не качайте образи і не піднімайте VM під час розмови. Образи вже в registry.
4. Перевірте фазу: `make status` показує `delivery phase`. Від неї залежить варіант нижче.

### Варіант A: свіжий стенд (фаза jenkins), показати весь шлях
Підготовка: `make destroy CONFIRM=lab && make up && make legacy-release VERSION=v1` (близько 20 хвилин).
Після цього фаза `jenkins`, v1 розгорнуто Jenkins-ом. Handoff виконується один раз; щоб повторити,
потрібен новий стенд. Якщо токен Jenkins (48 годин) старіє: `make refresh-deploy-token`.

### Варіант B: стенд уже в фазі argocd
Перший перехід Jenkins в Argo вдруге чесно не показати. Покажіть кінцевий стан і записані докази:
`docs/evidence/EVIDENCE.md` (UID до і після, відмова колишнього deploy-доступу). Починайте з кроку 5.
Ніколи не повертайте власника назад під час демо.

## Хід розмови

**0:00 Ідея (1 хв).** Один застосунок, три pod-и. Кожен приймає HTTP і слухає Redis Stream. POST на
одному pod-і підтверджують усі інші активні pod-и. Jenkins спочатку деплоїть сам, потім керування
переходить Argo CD; Jenkins залишає збірку й оновлення Git.

**1. Стан і адреси (1 хв).**

    make status
    make urls

**2. Fan-out (1 хв).**

    make broadcast MESSAGE=hello
    make smoke

Очікувано: `expected_count 2, received_count 2, status complete`; три pod-и дають два ACK, бо відправник
виключений. `make smoke` також публікує на `messenger-0` напряму і читає з `messenger-1`: різні `origin` і
`served_by`, ті самі ACK.

**3. Legacy-реліз Jenkins (варіант A, 1 хв).**

    make legacy-release VERSION=v1

Що показати у виводі: URL білда, тести (29 passed), digest образу, коміт у env, Helm revision, smoke.
Пояснити: chart закріплений на `CHART_COMMIT`, значення беруться з env-репозиторію, образ за digest.

**4. Handoff (варіант A, 3 хв).**

    make handoff-plan
    make handoff

`handoff-plan`: п'ять ресурсів OutOfSync, різниця лише в анотації `argocd.argoproj.io/tracking-id`. Нічого
не застосовано. `handoff`: фаза `handoff`, legacy job вимкнено, черга і білди зупинені; Jenkins RoleBinding
видалено; свіжий токен колишньої identity отримує `Forbidden` на dry-run зміни StatefulSet; ручний sync без
prune і self-heal; UID ресурсів і pod-ів, селектори, digest, шаблон pod-а ті самі; потім self-heal увімкнено;
фаза `argocd`. Це реальна межа прав, а не лише прапорець фази.

**5. GitOps-реліз (2 хв).**

    make gitops-release VERSION=v2

Jenkins збирає, тестує, пушить образ і робить один коміт з новим digest в env/main. Kubernetes він не
чіпає. Скрипт чекає, поки Argo зведе саме цю ревізію env і цей digest, і лише тоді показує `/identity`
з версією v2. Зелений Jenkins не доводить, що workload здоровий: це доводить Argo (sync і health).

**6. Self-heal і rollback (1 хв).**

    make drift-demo     # руками 5 реплік, Argo повертає 3 приблизно за 2 секунди
    make rollback       # git revert останнього release-коміту в env, історія зберігається

Пояснити: self-heal повертає стан із Git; prune видаляє ресурси, яких уже немає в Git (вимкнено, окрема
функція). Rollback це revert у Git, не `helm rollback`.

**7. Відновлення (1 хв, за часом).**

    make recovery-demo

Очікувано: `messenger-1` отримав подію і зупинився до ACK, pending = 1, pod видалено, нова
інкарнація з тим самим іменем і новим UID завершила зобов'язання, pending = 0. Статус `complete` (або
`complete_late`, якщо дедлайн 10 с минув).

## Швидке відновлення

| Симптом | Дія |
| --- | --- |
| Argo вікно не відкривається | `make argo-ui`, відкрити http://127.0.0.1:8443 |
| Jenkins agent offline | `make provision` (ідемпотентно), перевірити `make status` |
| Фраза `phase is argocd; the legacy job is retired` | очікувано: legacy вимкнений назавжди для цього стенду |
| `another lab command holds the transition lock` | дочекатися іншої команди; lock знімається сам |
| Handoff зупинився | фаза лишається `handoff`, доступ Jenkins відкликано; усунути причину, повторити `make handoff` |
| Застосунок недоступний | `kubectl --kubeconfig .lab/kubeconfig -n demo get pods`; `make status` |
| Забули дані входу | `make urls` показує, де лежать паролі (файли в `.lab/secrets/`) |

## Де докази

`docs/evidence/EVIDENCE.md` (оновити: `make collect-evidence`), `docs/evidence/baseline*.json`,
`docs/PROGRESS.md`. Білди Jenkins: `make urls` і далі `/job/messenger-legacy`, `/job/messenger-gitops`.

## Після співбесіди

    make halt                    # зупинити тільки ці VM
    make destroy CONFIRM=lab     # видалити тільки цей стенд
