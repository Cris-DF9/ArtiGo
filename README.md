# Faberio MVP

Marketplace locale Faberio, ottimizzato come web app mobile-first.

## Pubblicazione su Vercel

1. Usa il repository GitHub Faberio collegato a Vercel.
2. Carica tutti i file di questa cartella nella root del repository.
3. In Vercel scegli **Add New > Project**.
4. Importa il repository GitHub appena creato.
5. Framework Preset: **Other**.
6. Build Command: lascia vuoto.
7. Output Directory: lascia vuoto.
8. Premi **Deploy**.

Vercel pubblicherà automaticamente `index.html` come homepage.

## Struttura

- `index.html` - applicazione Faberio
- `vercel.json` - configurazione minima per hosting statico
- `.gitignore` - esclusioni Git standard
- `supabase/migrations` - schema, RLS, verifica professionisti e pagamenti
- `supabase/functions` - Stripe Connect, checkout, webhook e trasferimento finale

## Stato pagamenti

Il flusso è predisposto e resta inattivo finché non vengono configurate le credenziali Stripe e i dati fiscali definitivi di Faberio. I documenti dei professionisti sono conservati in un bucket Supabase privato.
