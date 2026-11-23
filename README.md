# Desafio Coração Forte – protótipos

Protótipos clicáveis do desafio de 21 dias da Dra. Hélia Beatriz (CRM-DF 16239, RQE 7825).
**Não é o app real**: são arquivos HTML de demonstração, com dados fictícios, para o desenvolvedor usar como referência.

## O que tem aqui
- `coracao-forte.html` – app do participante (missões, hábitos, quiz, pressão, conquistas, time, certificado).
- `crm-coracao-forte.html` – painel da equipe (participantes, engajamento, receita).
- `schema-rascunho.sql` – rascunho de banco de dados. **Não rodar** no Supabase real; o schema do dev prevalece.

## Como ver
Abra os arquivos `.html` no navegador. Não precisa instalar nada.

## Regras importantes
- Saúde: alertas de pressão e triagem seguem a revisão da Dra. Hélia e as normas do CFM (Res. 2.336/2023 e 2.386/2024). Não prometer cura ou resultado.
- LGPD: dados de pressão e triagem são dados de saúde; exigem consentimento e acesso restrito.
- Identidade visual: cores `#2a423d`, `#c7bfb4`, `#ffffff`; fonte Poppins.

## Segredos
Nunca publicar chaves, senhas ou tokens. Use um arquivo `.env` local (ignorado pelo git), com base no `.env.example`.
