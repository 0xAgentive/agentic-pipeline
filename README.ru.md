# Agentic Development Pipeline

Lokalnyy, strogyy i proveriaemyy freymvork dlia upravleniia razrabotkoy s AI-agentami v Google Antigravity.

Agentic Pipeline pomogaet ne dopuskat dreifa sostoyaniya, pereskakivaniya faz i nepodtverzhdennyh zayavleniy o gotovnosti.

---

## Tsennost i naznachenie

AI-assistenty bystro pishut kod, no chasto oshibayutsya v protsesse:

1. Agent nachinaet realizovyvat zadachu.
2. Menyaet desyatki faylov v raznyh chastyah proekta.
3. Obyavlyaet zadachu zavershennoy na osnovanii sobstvennoy logiki.
4. Sborka ili testy padayut, ili review pokazyvaet nezhelatelnye pobochnye effekty.

Agentic Pipeline reshaet etu problemu. On zadaet poshagovyy tsikl, gde agent ne perehodit k sleduyushchey faze bez deterministicheskih dokazatelstv: uspeshnyh proverok, chistogo diff, tochnyh komand terminala i yavnyh granits faz.

---

## Dlya kogo eto

- Razrabotchiki, kotorye ispolzuyut prodvinutyh AI-agentov, no hotyat sohranyat kontrol nad arhitekturoy i kachestvom koda.
- Timlidy, kotorym nuzhny pravila bezopasnoy AI-razrabotki v komande.
- Security i QA, kotorym nuzhny proveriaemye sledy izmeneniy i audit-ready evidence.

---

## Trekhsloynaya operatsionnaya model

ChatGPT Companion
  -> formuliruet idei, gotovit TZ, provodit research i audit, pishet prompts

Agentic Pipeline
  -> zadaet workflows, rules, hooks, validators, evidence gates

Product Project
  -> soderzhit realnyy kod, testy, .agy state i artefakty proverki

1. ChatGPT Companion - sloy myshleniya, research, audita i podgotovki tochnyh prompts. Eto ne ispolnitel.
2. Agentic Pipeline - sloy protsessa: workflows, durable rules, hooks, skills, validators i shablony.
3. Product Project - rabochaya papka prilozheniya ili instrumenta, gde nahodyatsya ishodniki, testy i dokazatelstva vypolneniya.

Vazhnyy invariant: slova modeli v chate ne yavlyayutsya proverkoy. Proverkoy yavlyayutsya komandy, exit codes, testy, diff, skrinshoty, logi i artefakty vnutri workspace.

---

## Bystryy start

### Novyy proekt

1. Skopiruyte templates/agy-project-base/ v papku novogo proekta.
2. Otkroyte etu papku v Antigravity.
3. Zapustite:

    /specdoc
    /planonly
    /nextphase

### Sushchestvuyushchiy proekt

Dlya sushchestvuyushchego proekta snachala vypolnite audit:

    /auditphase

Posle audita perehodite k odnoy faze realizatsii:

    /nextphase

---

## Karta komand

/specdoc       - sozdat ili obnovit spetsifikatsiyu bez koda
/planonly      - sozdat fazovyy plan bez realizatsii
/auditphase    - proverit tekushchee sostoyanie workspace
/probephase    - proverit riskovannye API, dannye, zhelezo ili prava
/nextphase     - realizovat rovno odnu fazu, proverit, zafiksirovat sostoyanie i ostanovitsya
/fastpatch     - malaya pravka tolko esli skript razreshil diff
/visualqa      - vizualnaya proverka UI
/securityaudit - proverka privatnosti, sekretov, eksporta i opasnyh deystviy
/shipcheck     - finalnaya proverka SHIP / NO-SHIP
/githubprepare - podgotovka GitHub-publikatsii
/githubsync    - bezopasnyy commit/push posle proverok

---

## Evidence-first SHIP / NO-SHIP

Reliznoe reshenie binarnoe:

- SHIP - tolko esli sostoyanie .agy/PHASE_STATUS.json soglasovano, proverki proydeny, evidence prisutstvuet, riski zakryty ili yavno prinyaty.
- NO-SHIP - esli est failed command, neproverennye claims, otsutstvuyushchie rollback notes, visual/security/report blockers ili dreif trebovaniy.

---

## Navigatsiya po dokumentatsii

- Start: [START_HERE.en.md](docs/START_HERE.en.md) / [START_HERE.ru.md](docs/START_HERE.ru.md)
- Context Split: [CONTEXT_SPLIT.ru.md](docs/concepts/CONTEXT_SPLIT.ru.md)
- Indeks dokumentatsii: [docs/README.md](docs/README.md)
- Matritsa versiy: [docs/PIPELINE_VERSION_MATRIX.md](docs/PIPELINE_VERSION_MATRIX.md)

---

## Litsenziya

Proekt rasprostranyaetsya pod litsenziey MIT. Podrobnosti v fayle [LICENSE](LICENSE).
