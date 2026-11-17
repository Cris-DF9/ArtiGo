# DEFIMEL: salvataggio e recupero bolle

## Stato al 21 ottobre 2026

Proposta non applicata in produzione. Verifica effettiva, in sola lettura, sul progetto
`fruzlkaqrogdfmzpwbft`, corrispondente all'URL in `defimel.html`: PostgreSQL 17.6,
30 bolle, 0 bolle senza righe, 0 numeri duplicati confrontando `lower(btrim(numero))`.
Questo non prova la correttezza commerciale di ogni riga né esclude errori storici
parziali. Non sono state modificate bolle, foto, utenti, policy o funzioni in produzione.
Base esaminata: commit `52f5bdf`, incluso il controllo introdotto da `eddee2296bbf92b7bbf956587a50acc93690c2bd`.

Il repository contiene anche migrazioni Faberio: **non eseguire un db push generico**.
Lo SQL DEFIMEL è isolato in `defimel-db/proposals/atomic-deliveries.sql` e non è una
migrazione applicata o registrata. Generare la migrazione con la CLI Supabase solo
nel progetto corretto, dopo la validazione in staging.

## Problemi verificati e soluzione

- `newDelivery()` caricava foto, intestazione e articoli in tre richieste. Il catch
  sostituiva anche errori reali dei materiali con «Bolla già inserita».
- `ilike` interpretava `%` e `_` come jolly. Le RLS impediscono a un operaio di vedere
  le bolle altrui: il controllo client non poteva garantire unicità globale. Nessun
  indice univoco sul numero risultava presente in produzione.
- `confirmDelivery()` ignorava errori sulle singole scritture e poteva confermare
  una bolla vuota o ripetere parte della registrazione dei materiali.

La RPC `defimel_save_delivery` inserisce documento e articoli in **una transazione**.
Qualsiasi errore annulla entrambi. Le policy RLS esistenti restano attive; le RPC
sono SECURITY INVOKER, disponibili solo ad authenticated, con verifica profilo attivo.
L'indice univoco mantiene la regola richiesta: stesso numero in tutta DEFIMEL, a
prescindere da cantiere, fornitore e anno; confronto letterale, senza distinzione di
maiuscole e ignorando spazi esterni. Non estendere a fornitore/anno senza una decisione
esplicita. Duplicati preesistenti impediscono l'applicazione atomica dello SQL: nessuna
riga viene eliminata o rinumerata.

Un trigger differito rifiuta le nuove intestazioni senza articoli al commit. Blocca
anche i vecchi client in cache che tentano ancora le due scritture separate. Le
bolle storiche vuote non vengono modificate retroattivamente.

Ogni salvataggio ha un UUID e uno snapshot dei dati. Prima della RPC, il browser
conserva l'operazione in localStorage, separata per utente e UUID. Dopo una risposta
persa, «Salva bolla» oppure «Inserisci bolla» dopo riapertura ripete lo stesso UUID e
lo stesso contenuto. La RPC riconosce un'operazione già completata, anche dopo la
conferma dell'amministratore, senza duplicare righe. UUID riutilizzati con dati diversi
vengono rifiutati. Più schede non cancellano i tentativi delle altre schede.
Un errore SQL certo cancella il tentativo locale e permette di correggere i dati;
un errore di rete lo conserva. Una RPC mancante mostra un errore esplicito, senza
ripiegare sul vecchio salvataggio non atomico.

La RPC `defimel_confirm_delivery` blocca la bolla e serializza le conferme dello
stesso cantiere, registra i materiali e conferma il documento nella stessa transazione.
Una seconda conferma non aggiunge materiali. Conserva la logica di abbinamento per
nome/unità; non cambia le quantità delle richieste esistenti. Popola anche il collegamento
`linked_material_request_id` già presente nello schema.

## Foto e operazioni interrotte

Storage e PostgreSQL non condividono una transazione. La foto viene caricata prima
ed è verificata dalla RPC con le policy esistenti. Un errore upload non avvia la RPC.
Non si cancellano automaticamente foto dopo timeout: potrebbero essere già collegate
a un salvataggio riuscito. Un'interruzione prima del journal, una quota locale esaurita
o un rollback certo possono lasciare una **foto orfana**, ma non una bolla incompleta.
Per la pulizia futura confrontare Storage e riferimenti DB, escludere operazioni
pendenti e applicare un intervallo di sicurezza; nessuna pulizia è inclusa qui.
Non eliminare la memoria del browser durante un tentativo incerto. Se la memoria
locale viene persa o si cambia dispositivo, il vincolo DB continua a impedire doppioni;
verificare la bolla esistente prima di procedere.

L'OCR continua a usare la Edge Function esistente. Una nuova foto invalida le righe
precedenti; una lettura iniziata sulla foto precedente non può abilitare il salvataggio.
La pulizia delle foto temporanee OCR è ancora best-effort: non è una transazione Storage.

## Recupero storico

Solo l'amministratore vede «Recupera materiali» per bolle pending_review senza righe.
Seleziona nuovamente la foto originale, legge e controlla tutti gli articoli. La RPC
blocca e ricontrolla la bolla: aggiunge solo le righe, mantenendo UUID, autore,
numero, data, cantiere, fornitore, foto e testo OCR già archiviati. Le bolle complete,
confermate o con dati cambiati nel frattempo non vengono sovrascritte. È necessario
un numero non vuoto. Le bolle con alcune righe mancanti o altri problemi richiedono
verifica manuale: non sono identificate automaticamente come recuperabili.

## Test riproducibili

```sh
npm ci --prefix tests/defimel --ignore-scripts
npm test --prefix tests/defimel
```

Test SQL su PostgreSQL WASM (PGlite), schema/policy/grant/helper estratti in sola
lettura dalla produzione; utenti, cantieri e Storage sono sintetici. Snapshot senza
dati delle bolle o dati personali. Test DOM su tutti e tre gli ingressi:
`defimel.html`, `defimel-prova.html`, `defimel-cantieri/index.html`.

Copertura: commit singolo, errore articolo/rollback, retry stesso UUID, payload diverso,
duplicato invisibile per RLS, maiuscole/spazi/jolly letterali, foto mancante, utente
inattivo, segretaria, anonimo, vecchio client, recupero admin e conservazione metadati,
conferma fallita/rollback/retry, upload fallito, risposta persa, journal separato per
utente e operazione, riga invalida, RPC assente. Verificata anche la sintassi dei moduli
JavaScript e l'assenza di modifiche al codice login.

**Limiti**: PGlite usa una sola connessione; non dimostra contesa tra sessioni reali.
Non sono stati effettuati login interattivi, chiamate OCR vere o upload di prova in
produzione. Prima dell'attivazione testare in staging, via API e sessioni separate:

1. Due utenti salvano simultaneamente numeri identici: uno solo riesce, nessuna riga
   residua del perdente. Ripetere con stesso UUID e payload: entrambi ricevono lo stesso ID.
2. Interrompere la risposta HTTP dopo commit, ricaricare e riprendere il tentativo;
   verificare UUID, quantità righe e fotografia. Ripetere dopo conferma amministrativa.
3. Due conferme simultanee dello stesso documento e di documenti dello stesso cantiere:
   nessun materiale ripetuto, abbinamenti coerenti, eventuali deadlock ritentabili.
4. Admin, segretaria, operaio attivo/inattivo e anonimo: login, visibilità cantieri,
   upload, OCR, inserimento, consultazione, export e rapportini.
5. Recupero di una bolla vuota sintetica: metadati immutati; secondo recupero e tentativi
   su bolle complete/confermate rifiutati. Simulare caduta connessione durante recupero.

## Attivazione e verifica

1. Eseguire `defimel-db/preflight.sql` sul progetto DEFIMEL e confrontare lo schema
   con lo snapshot. Rilevare conteggi e backup prima dell'intervento. Se schema,
   policy, duplicati o trigger sono cambiati, rivalutare la proposta.
2. Applicare e verificare lo SQL in staging e completare i test API/concorrenza sopra.
3. Coordinare una breve finestra di aggiornamento: SQL prima, frontend subito dopo.
   Dopo lo SQL i vecchi client non possono più salvare intestazioni separate: devono
   ricaricare la pagina. Non pubblicare il frontend da solo: manca la RPC.
4. Dopo applicazione verificare `pg_proc.prosecdef=false`, grant EXECUTE, indice univoco,
   trigger differito, policy immutate e conteggi preesistenti. Il deploy HTML non prova
   che il database sia aggiornato.
5. Verificare un salvataggio autorizzato via app e la relativa fotografia/righe, il
   retry e la conferma. Dichiarare l'intervento operativo solo dopo questi controlli.

Per interrompere un rollout fallito sospendere temporaneamente l'inserimento bolle:
non rimuovere il vincolo o il trigger per riabilitare il vecchio flusso incompleto.
Non eliminare `save_payload`, le foto o righe già create per effettuare un rollback.

## Altre osservazioni, fuori da questa modifica

La cancellazione esistente elimina la foto prima della riga DB: un errore successivo
può lasciare una bolla senza foto. Non è stata modificata perché richiede una gestione
separata della cancellazione/ritenzione. Anche `load()` può nascondere errori di lettura
su alcune tabelle; la RPC ricontrolla lato server prima di recuperare o confermare.
Nessuna modifica a login, Edge Functions, rapportini, export, dati Faberio o RLS.

Riferimento API verificato: https://supabase.com/docs/guides/database/functions
Changelog consultato: https://supabase.com/changelog.md (aggiornamenti TLS e minor
PostgreSQL non cambiano il contratto RPC utilizzato).
