
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const PUB = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default || Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") || "";

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
  "content-type": "application/json",
  "cache-control": "no-store"
};

const J = (x:any, status=200) => new Response(JSON.stringify(x), {status, headers:cors});

Deno.serve(async (req:Request) => {
  if (req.method === "OPTIONS") return new Response("ok", {headers:cors});
  if (req.method !== "POST") return J({error:"Metodo non consentito"}, 405);
  if (!OPENAI_API_KEY) return J({error:"AI_NOT_CONFIGURED", message:"Manca OPENAI_API_KEY nei secrets Supabase."}, 503);

  const auth = req.headers.get("authorization") || "";
  if (!auth.toLowerCase().startsWith("bearer ")) return J({error:"Non autorizzato"}, 401);

  const sb = createClient(SUPABASE_URL, PUB, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession:false }
  });

  const {data:{user}, error:userErr} = await sb.auth.getUser();
  if (userErr || !user) return J({error:"Sessione non valida"}, 401);

  const {data:profile} = await sb.from("profiles").select("id,active,role").eq("id", user.id).maybeSingle();
  if (!profile?.active) return J({error:"Account non abilitato"}, 403);

  let body:any={};
  try { body = await req.json(); } catch { return J({error:"Richiesta non valida"}, 400); }
  const path = String(body.path || "");
  if (!path.startsWith(user.id + "/")) return J({error:"File non consentito"}, 403);

  const {data:signed, error:signedErr} = await sb.storage.from("defimel-files").createSignedUrl(path, 300);
  if (signedErr || !signed?.signedUrl) return J({error:"Impossibile leggere la bolla"}, 400);

  const prompt = `
Analizza questa fotografia di un documento di trasporto/DDT italiano per materiale elettrico.
Estrai i dati in modo strutturato. Il documento può provenire da Elettroveneta, Marchiol, Sonepar o altri grossisti.

Regole importanti:
- Non inventare righe o valori.
- Ignora intestazioni, note ambientali, riferimenti ordine, condizioni di pagamento, firme e totali generali quando non sono righe articolo.
- "quantity" è la quantità consegnata.
- "unit" è l'unità di misura stampata (es. PZ, M, MT, KG, CF).
- "unit_price" è il prezzo stampato nella colonna prezzo, senza IVA.
- "price_basis" conserva eventuali basi/moltiplicatori come "/C", "/D", "/M", "x 1.000".
- "line_total" è l'importo finale della riga se chiaramente visibile, altrimenti 0.
- "vat_rate" è l'aliquota IVA della riga se chiaramente visibile, altrimenti 0.

Regole specifiche Sonepar:
- Se il fornitore è Sonepar, leggi SOLO le righe della tabella articoli centrale.
- La colonna DESCRIZIONE ARTICOLO contiene la descrizione del materiale.
- La colonna CODICE ARTICOLO contiene il codice articolo.
- La colonna U.M. contiene l'unità di misura.
- La colonna QUANTITA contiene la quantità consegnata.
- La colonna PREZZO x MOLTIPLICAZIONE contiene il prezzo stampato e il relativo moltiplicatore.
- Esempio "606,00 x 1.000": unit_price = 606.00 e price_basis = "x 1.000".
- La colonna IMPORTO € contiene il totale finale della riga e va sempre usata per line_total quando è leggibile.
- NON calcolare line_total dal prezzo se l'importo finale è già stampato nel documento.
- NON confondere IMPORTO € con unit_price.
- Mantieni ogni descrizione allineata alla stessa riga di codice, unità, quantità, prezzo e importo.
- Esempio tipico Sonepar: quantità 200, prezzo "606,00 x 1.000", importo riga 121,20 -> quantity=200, unit_price=606.00, price_basis="x 1.000", line_total=121.20.

- Per date restituisci YYYY-MM-DD.
- Se un campo non è leggibile usa stringa vuota o 0; non fare supposizioni.
- Mantieni la descrizione articolo il più fedele possibile al documento.
- REGOLA SPECIFICA SONEPAR: se il fornitore è Sonepar, nella tabella articoli interpreta le colonne così:
  1) "DESCRIZIONE ARTICOLO" = description;
  2) "CODICE ARTICOLO" = code;
  3) "U.M." = unit;
  4) "QUANTITA" = quantity;
  5) "PREZZO x MOLTIPLICAZIONE" = unit_price + price_basis. Esempio "606,00 x 1.000" => unit_price 606.00 e price_basis "x 1.000";
  6) "IMPORTO €" = line_total, cioè importo finale già calcolato della riga.
- Per Sonepar NON calcolare line_total dal prezzo se la colonna "IMPORTO €" è leggibile: usa sempre il valore stampato in quella colonna.
- Per Sonepar non confondere il prezzo rosa con l'importo finale: il prezzo/moltiplicatore è una cosa, l'importo riga è un'altra.
`;

  const schema = {
    type:"object",
    additionalProperties:false,
    properties:{
      supplier:{type:"string"},
      document_number:{type:"string"},
      document_date:{type:"string"},
      items:{
        type:"array",
        items:{
          type:"object",
          additionalProperties:false,
          properties:{
            code:{type:"string"},
            description:{type:"string"},
            quantity:{type:"number"},
            unit:{type:"string"},
            unit_price:{type:"number"},
            price_basis:{type:"string"},
            line_total:{type:"number"},
            vat_rate:{type:"number"}
          },
          required:["code","description","quantity","unit","unit_price","price_basis","line_total","vat_rate"]
        }
      }
    },
    required:["supplier","document_number","document_date","items"]
  };

  const oa = await fetch("https://api.openai.com/v1/responses", {
    method:"POST",
    headers:{
      "authorization":"Bearer "+OPENAI_API_KEY,
      "content-type":"application/json"
    },
    body:JSON.stringify({
      model:"gpt-6-luna",
      input:[{
        role:"user",
        content:[
          {type:"input_text", text:prompt},
          {type:"input_image", image_url:signed.signedUrl, detail:"high"}
        ]
      }],
      text:{
        format:{
          type:"json_schema",
          name:"ddt_extraction",
          strict:true,
          schema
        }
      }
    })
  });

  const data = await oa.json();
  if (!oa.ok) {
    console.error("OpenAI error", oa.status, data);
    return J({error:"AI_ERROR", message:data?.error?.message || "Errore durante la lettura AI"}, 502);
  }

  let outText = data.output_text || "";
  if (!outText && Array.isArray(data.output)) {
    for (const item of data.output) {
      for (const part of (item?.content || [])) {
        if (part?.type === "output_text" && part?.text) outText += part.text;
      }
    }
  }
  if (!outText) return J({error:"AI_EMPTY", message:"Nessun dato restituito dall'AI"}, 502);

  let parsed:any;
  try { parsed = JSON.parse(outText); } catch {
    console.error("Invalid AI JSON", outText);
    return J({error:"AI_PARSE", message:"Risposta AI non valida"}, 502);
  }

  parsed.items = (parsed.items || []).filter((x:any) => x.description && Number(x.quantity) > 0);
  return J(parsed);
});
