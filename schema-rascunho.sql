-- ATENCAO: RASCUNHO. Nao rode no projeto real do Supabase; o banco do dev ja tem schema proprio.
-- =====================================================================
-- Desafio Coração Forte · estrutura do banco (Supabase / Postgres)
-- Alimenta o app do participante e o painel da equipe (CRM).
--
-- Fluxo dos dados:
--   1. Checkout (Hotmart/Kiwify/Eduzz) -> webhook -> Edge Function
--      cria/atualiza: participants + purchases (e o usuário no Supabase Auth)
--   2. App do participante grava cada ação em `events`
--   3. Painel lê as views v_participant_status, v_cohort_daily_active, v_cohort_summary
--   4. Um job diário (pg_cron ou Edge Function agendada) lê v_participant_status
--      e dispara as automações, registrando cada envio em `messages`
--
-- LGPD: medições de pressão e triagem ficam em tabelas próprias, visíveis só
-- para o próprio participante. A equipe não acessa esses valores pelo painel.
-- =====================================================================

-- ---------- Turmas ----------
create table cohorts (
  id            bigint generated always as identity primary key,
  name          text not null,                 -- "Turma 5"
  start_date    date not null,                 -- dia 1 do desafio
  sales_open_at timestamptz,
  price_cents   int  not null default 3700,
  created_at    timestamptz not null default now()
);

-- ---------- Participantes ----------
create table participants (
  id              uuid primary key references auth.users(id) on delete cascade,
  cohort_id       bigint not null references cohorts(id),
  full_name       text not null,
  email           text not null,
  phone           text,                        -- E.164: +5561999999999
  team            text check (team in ('Aorta','Ventrículo','Átrio','Válvula')),
  origin          text,                        -- Stories, Link da bio, Tráfego pago, Indicação, E-mail
  referred_by     uuid references participants(id),
  referral_code   text unique,
  first_access_at timestamptz,                 -- preenchido no 1º login (dia 0 / triagem)
  consent_health_at timestamptz,               -- aceite do termo de dados de saúde
  created_at      timestamptz not null default now()
);
create index on participants (cohort_id);

-- ---------- Compras (vindas do webhook do checkout) ----------
create table purchases (
  id              bigint generated always as identity primary key,
  participant_id  uuid references participants(id) on delete set null,
  cohort_id       bigint not null references cohorts(id),
  provider        text not null,               -- hotmart | kiwify | eduzz
  provider_tx_id  text not null unique,        -- garante que o webhook não duplique compra
  status          text not null check (status in ('paid','refunded','chargeback','pending')),
  amount_cents    int  not null,
  order_bump      boolean not null default false,
  utm_source      text, utm_medium text, utm_campaign text, utm_content text,
  paid_at         timestamptz,
  raw             jsonb,                       -- payload original do webhook, para auditoria
  created_at      timestamptz not null default now()
);
create index on purchases (cohort_id, status);

-- ---------- Eventos do app (a fonte de toda métrica de engajamento) ----------
create table events (
  id              bigint generated always as identity primary key,
  participant_id  uuid not null references participants(id) on delete cascade,
  cohort_id       bigint not null references cohorts(id),
  day             smallint not null check (day between 0 and 21),
  type            text not null check (type in (
                    'first_access','triage_done','video_watched','mission_done',
                    'habit_checked','quiz_answered','bp_official','bp_extra',
                    'level_up','badge_earned','story_shared','referral_sent')),
  points          smallint not null default 0,
  meta            jsonb not null default '{}', -- ex.: {"habit":"agua"} | {"correct":true} | {"badge":"detetive_sal"}
  created_at      timestamptz not null default now()
);
create index on events (cohort_id, day);
create index on events (participant_id, created_at desc);

-- Conta como "check-in do dia" quem fez a missão ou marcou ao menos um hábito.
create view v_checkins as
select distinct participant_id, cohort_id, day
from events
where type in ('mission_done','habit_checked') and day between 1 and 21;

-- ---------- Dados de saúde (somente o próprio participante enxerga) ----------
create table bp_readings (
  id              bigint generated always as identity primary key,
  participant_id  uuid not null references participants(id) on delete cascade,
  day             smallint not null check (day between 0 and 21),
  official        boolean not null default false,  -- dias 1, 7, 14, 21
  systolic        smallint not null check (systolic between 60 and 300),
  diastolic       smallint not null check (diastolic between 30 and 200),
  pulse           smallint check (pulse between 30 and 220),
  measured_at     timestamptz not null default now()
);

create table triage_answers (
  participant_id  uuid primary key references participants(id) on delete cascade,
  heart_disease   boolean, symptoms boolean, cardio_meds boolean, pregnant boolean,
  answered_at     timestamptz not null default now()
);

-- ---------- Clube (assinatura recorrente) ----------
create table subscriptions (
  id              bigint generated always as identity primary key,
  participant_id  uuid not null references participants(id) on delete cascade,
  provider        text not null,
  provider_sub_id text not null unique,
  status          text not null check (status in ('active','past_due','canceled')),
  amount_cents    int  not null default 3900,
  started_at      timestamptz not null default now(),
  canceled_at     timestamptz
);

-- ---------- Automações e mensagens ----------
create table automation_rules (
  key        text primary key,          -- naoentrou | boasvindas | lembrete | risco | sumido | concluiu
  title      text not null,
  trigger    text not null,             -- descrição legível da regra
  channel    text not null,             -- whatsapp | email | push
  template   text not null,             -- usa {{first_name}} e {{link}}
  active     boolean not null default true
);

create table messages (
  id              bigint generated always as identity primary key,
  participant_id  uuid not null references participants(id) on delete cascade,
  rule_key        text references automation_rules(key),
  channel         text not null,
  status          text not null default 'sent' check (status in ('queued','sent','delivered','read','failed')),
  sent_at         timestamptz not null default now()
);
create index on messages (participant_id, sent_at desc);

-- ---------- Equipe ----------
create table staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role in ('admin','suporte'))
);

create table staff_notes (
  id              bigint generated always as identity primary key,
  participant_id  uuid not null references participants(id) on delete cascade,
  author_id       uuid not null references staff(user_id),
  body            text not null,
  created_at      timestamptz not null default now()
);

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid())
$$;

-- =====================================================================
-- VIEWS DO PAINEL
-- =====================================================================

-- Dia atual de cada turma, no fuso de Brasília (0 = antes de começar, 22+ = concluída)
create view v_cohort_day as
select c.*,
       ((now() at time zone 'America/Sao_Paulo')::date - c.start_date) + 1 as today_day,
       case
         when ((now() at time zone 'America/Sao_Paulo')::date - c.start_date) + 1 < 1  then 'vendas'
         when ((now() at time zone 'America/Sao_Paulo')::date - c.start_date) + 1 > 21 then 'concluida'
         else 'andamento'
       end as state
from cohorts c;

-- Status de cada participante (é o que o painel lista e o que as automações leem)
create view v_participant_status as
with last_ci as (
  select participant_id, max(day) as last_day, count(*) as active_days
  from v_checkins group by participant_id
),
pts as (
  select participant_id, sum(points) as points,
         count(*) filter (where type = 'mission_done') as missions
  from events group by participant_id
)
select p.id, p.cohort_id, p.full_name, split_part(p.full_name,' ',1) as first_name,
       p.phone, p.email, p.team, p.origin, p.first_access_at,
       cd.today_day, cd.state as cohort_state,
       coalesce(l.last_day,0)    as last_checkin_day,
       coalesce(l.active_days,0) as active_days,
       coalesce(t.points,0)      as points,
       coalesce(t.missions,0)    as missions,
       exists (select 1 from subscriptions s where s.participant_id = p.id and s.status = 'active') as club_active,
       case
         when p.first_access_at is null                                   then 'naoentrou'
         when cd.state = 'concluida' and coalesce(l.last_day,0) >= 20     then 'concluiu'
         when cd.state = 'concluida'                                      then 'naoconcluiu'
         when least(cd.today_day,21) - coalesce(l.last_day,0) <= 1        then 'ativo'
         when least(cd.today_day,21) - coalesce(l.last_day,0) <= 3        then 'risco'
         else 'sumido'
       end as status
from participants p
join v_cohort_day cd on cd.id = p.cohort_id
left join last_ci l on l.participant_id = p.id
left join pts     t on t.participant_id = p.id;

-- Curva dos 21 dias: % de quem entrou que fez check-in em cada dia
create view v_cohort_daily_active as
with entered as (
  select cohort_id, count(*) as n from participants
  where first_access_at is not null group by cohort_id
)
select ci.cohort_id, ci.day,
       count(distinct ci.participant_id)                                   as active,
       e.n                                                                 as entered,
       round(100.0 * count(distinct ci.participant_id) / nullif(e.n,0), 1) as pct_active
from v_checkins ci join entered e using (cohort_id)
group by ci.cohort_id, ci.day, e.n;

-- Resumo por turma (tela Turmas + blocos da Visão geral)
create view v_cohort_summary as
select cd.id as cohort_id, cd.name, cd.start_date, cd.today_day, cd.state,
       (select count(*) from purchases pu where pu.cohort_id = cd.id and pu.status = 'paid') as buyers,
       (select coalesce(sum(amount_cents),0) from purchases pu where pu.cohort_id = cd.id and pu.status = 'paid') as revenue_cents,
       (select count(*) from purchases pu where pu.cohort_id = cd.id and pu.status = 'paid' and pu.order_bump) as order_bumps,
       count(*) filter (where s.status <> 'naoentrou')   as entered,
       count(*) filter (where s.status = 'ativo')        as ativo,
       count(*) filter (where s.status = 'risco')        as risco,
       count(*) filter (where s.status = 'sumido')       as sumido,
       count(*) filter (where s.status = 'naoentrou')    as nao_entrou,
       count(*) filter (where s.status = 'concluiu')     as concluiu,
       count(*) filter (where s.club_active)             as club,
       (select active from v_cohort_daily_active d where d.cohort_id = cd.id and d.day = 7)  as active_day7,
       (select active from v_cohort_daily_active d where d.cohort_id = cd.id and d.day = 14) as active_day14
from v_cohort_day cd
left join v_participant_status s on s.cohort_id = cd.id
group by cd.id, cd.name, cd.start_date, cd.today_day, cd.state;

-- =====================================================================
-- SEGURANÇA (Row Level Security)
-- Participante: lê e grava só os próprios dados.
-- Equipe: lê dados de compra e engajamento; NUNCA bp_readings nem triage_answers.
-- As views do painel devem ser consultadas com a sessão de um usuário da equipe
-- (ou expostas por uma Edge Function que confere is_staff()).
-- =====================================================================
alter table participants   enable row level security;
alter table purchases      enable row level security;
alter table events         enable row level security;
alter table bp_readings    enable row level security;
alter table triage_answers enable row level security;
alter table subscriptions  enable row level security;
alter table messages       enable row level security;
alter table staff_notes    enable row level security;
alter table automation_rules enable row level security;

create policy own_profile   on participants   for select using (id = auth.uid() or is_staff());
create policy own_update    on participants   for update using (id = auth.uid());
create policy own_events_r  on events         for select using (participant_id = auth.uid() or is_staff());
create policy own_events_w  on events         for insert with check (participant_id = auth.uid());
create policy own_bp        on bp_readings    for all    using (participant_id = auth.uid()) with check (participant_id = auth.uid());
create policy own_triage    on triage_answers for all    using (participant_id = auth.uid()) with check (participant_id = auth.uid());
create policy staff_purch   on purchases      for select using (is_staff() or participant_id = auth.uid());
create policy staff_subs    on subscriptions  for select using (is_staff() or participant_id = auth.uid());
create policy staff_msgs    on messages       for select using (is_staff());
create policy staff_notes_a on staff_notes    for all    using (is_staff()) with check (is_staff());
create policy staff_rules   on automation_rules for all  using (is_staff()) with check (is_staff());
-- Inserções em purchases, subscriptions e messages são feitas pelas Edge Functions
-- com a service role (webhook do checkout e job de automações), que ignora RLS.

-- Pontuação: para evitar fraude no placar, o ideal é o app chamar uma Edge Function
-- (ou função SQL security definer) que valida o tipo de evento, o dia e o limite
-- de pontos por dia antes de inserir em `events`.

-- ---------- Regras de automação iniciais ----------
insert into automation_rules (key, title, trigger, channel, template) values
 ('boasvindas','Boas-vindas','Na compra','whatsapp','Bem-vinda ao Coração Forte, {{first_name}}! Seu acesso: {{link}}'),
 ('naoentrou','Comprou e não entrou','24h após a compra sem primeiro acesso','whatsapp','Oi, {{first_name}}! Seu acesso ao Desafio Coração Forte está pronto: {{link}}'),
 ('lembrete','Missão do dia','Todo dia às 7h','push','Bom dia, {{first_name}}! A missão de hoje já chegou.'),
 ('risco','Em risco','2 dias sem check-in','whatsapp','{{first_name}}, sentimos sua falta! A missão de hoje leva 10 minutos: {{link}}'),
 ('sumido','Sumido','4 dias sem check-in','whatsapp','Oi, {{first_name}}. Dá pra retomar de onde parou: {{link}}'),
 ('concluiu','Concluiu e oferta do Clube','Ao terminar o dia 21','whatsapp','{{first_name}}, você concluiu os 21 dias! Conheça o Clube Coração Forte: {{link}}');
