# Business facts — [PROJEKT]

<!-- Read by qa-gate (check `spec` in the pr stage, rule `legal.spec-consistency` in compliance). The fenced block
     below is the only part the gate parses; everything else on this page is for humans. Fill every [TODO].
     These are business decisions, not technical ones: they decide which German/EU duties apply. The gate never
     lowers a requirement because of this block — it only warns when config, site and spec disagree. -->

```qa-gate
sector: [TODO gastro | handwerk | pflege | versicherung | steuerberatung | rechtsanwalt | arzt | immobilien | kfz | leave empty]
ordering: [TODO none | phone | online]        # how customers order: none (information only), by phone, online
delivery: [TODO none | pickup | delivery | both]
payments: [TODO none | on-site | online]       # online payments make it a shop (PAngV, Widerruf, Muster-Widerrufsformular)
forms: [TODO true | false]                     # a form that collects an e-mail address
newsletter: [TODO true | false]
ai: [TODO none | chatbot | generated-content | both]
consumers: [TODO true | false]                 # B2C — BFSG accessibility statement, consumer duties
stand: [TODO YYYY-MM-DD]                        # the day these facts were confirmed
status: active                                  # active | deprecated (a deprecated block is ignored)
```

## What each fact changes

- `payments: online` → the shop rules run (delivery costs, delivery time, Muster-Widerrufsformular, 30-day price).
  Food prepared and delivered or collected within minutes has no right of withdrawal (§ 312g Abs. 2 Nr. 2 BGB).
- `ordering: phone | online` in gastro → allergen information must be reachable before the order (LMIV Art. 14).
- `forms: true` → every such form needs a Datenschutz hint next to it (DSGVO Art. 13).
- `ai: chatbot | generated-content` → KI-VO Art. 50 duties and the AI-Act register.
- `consumers: true` → `/barrierefreiheit` (§ 19 BFSGV) and the consumer rules of the sector pack.

Confirmed by: [TODO name], on [TODO date]. Lawyer consulted: [TODO yes/no, who].
