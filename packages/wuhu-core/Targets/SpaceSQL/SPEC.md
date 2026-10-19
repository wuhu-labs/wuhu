# SpaceSQL

## Read pool lifetime

`ReadPool.close()` drains each read slot, closes its SQLite connection, and refuses later queries and table discovery with `SQLITE_MISUSE`, including on slots never opened. Close is idempotent, attempts every slot even if one fails, and throws the first SQLite close failure.

## Conversation views

Grouped conversation views expose nullable `title` from the additive `conversation_titles` side table. Unqualified conversations include the acting group's readable conversations and memberships; qualified and wildcard names retain their group scope. `users` channels admit person members and sessions in groups reading the home group. Group access alone does not admit a non-member person. Session membership rows left in historical users channels are omitted from `conversation_members`; channel membership exposes only people. Message and member views use the same channel visibility as conversations. Non-channel conversation visibility remains unchanged.

`subscriptions` is a live projection of public observe/timer registrations, with columns `id`, `session_id`, `kind` (`observe` or `timer`), `sql`, `schedule`, `handler`, `armed_at`, `last_fired_at`, and `last_error`. Observer `sql` is populated and `schedule` is NULL; timer `schedule` is the original UTC cron expression or the original one-shot UTC ISO timestamp with milliseconds, and `sql` is NULL. Handler and last error are nullable. Internal park reminders/request deadlines, persisted handler state, attempt tokens and failure flags remain hidden. Registration rows inherit their owner's session group visibility: unqualified views read the acting group; group-qualified views require readability; the wildcard view includes `grp` and all readable groups. The projection reads the existing subscription payload and session rows without creating a materialized table or schema migration; queries/observations track both underlying tables. Direct internal-table access and forged view names remain refused by the authorizer.

`session_model_routes` and `session_model_route_history` are induced readonly grouped projections: unqualified queries read the acting group, readable qualified groups and wildcard queries follow the same access policy as sessions. It exposes concrete provider/model, member, route epoch, pinned phase and persisted nonsecret placement evidence. Direct sessions without a route are left-joinable and retain their concrete requested executor configuration.
