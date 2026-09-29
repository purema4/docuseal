# Create templates from PDF and DOCX via API

`POST /api/templates/pdf` and `POST /api/templates/docx` create a template from one or more documents.
The request format follows the `createTemplateFromPdf` / `createTemplateFromDocx` operations in
[`openapi.json`](openapi.json), so the official DocuSeal API clients work with these endpoints.

## Fields

Fields can be defined in two ways, and both can be combined:

1. **Text tags** in the document, e.g. `{{Full Name;role=Buyer}}` or
   `{{Sign here;type=signature;role=Seller;width=150;height=40}}`. The field is placed where the tag is
   printed and the tag text is removed from the document (pass `"remove_tags": false` to keep it).

   | Attribute  | Description                                                                   |
   |------------|-------------------------------------------------------------------------------|
   | `name`     | Field name (the first segment of the tag when `name=` is omitted)             |
   | `role`     | Signer role; roles are created in order of appearance (default `First Party`) |
   | `type`     | `text` (default), `signature`, `initials`, `date`, `number`, `image`, `file`, `select`, `checkbox`, `multiple`, `phone`, `stamp`, `cells`, ... |
   | `options`  | Comma separated options for `select` / `multiple`                             |
   | `required` | `false` makes the field optional (default `true`)                             |
   | `readonly` | `true` makes the field read-only                                              |
   | `default`  | Default value                                                                 |
   | `format`   | Date/signature/number format                                                  |
   | `width`, `height` | Field size in PDF points (defaults to the size of the tag text)         |

   Tags with the same name and role become one field with multiple areas.

2. **`fields` param** per document. `areas[].page` starts from 1. `x`, `y`, `w`, `h` are relative to the page
   (`0..1`) when all of them are `<= 1`, otherwise they are PDF points from the top left corner of the page.
   A `fields` entry with the same `name` and `role` as a tag overrides the tag attributes.

If a document has no tags and no `fields`, existing PDF form fields are imported (unless `"flatten": true`).

## Example

```shell
curl -X POST https://your-docuseal/api/templates/docx \
  -H "X-Auth-Token: $API_KEY" -H "Content-Type: application/json" \
  -d "{\"name\":\"NDA\",\"documents\":[{\"name\":\"nda\",\"file\":\"$(base64 -w0 nda.docx)\"}]}"

# Multipart upload (requires the X-Auth-Token header)
curl -X POST https://your-docuseal/api/templates/pdf \
  -H "X-Auth-Token: $API_KEY" -F "name=NDA" -F "documents[][file]=@nda.pdf"
```

`file` accepts base64 (optionally as a `data:` URI), a public `https://` URL, or a multipart upload.
Sending an `external_id` that already exists in the account replaces the documents and fields of that template.

## MCP

The MCP `create_template` tool uses the same processing: pass an HTTPS `url` of a PDF or DOCX file and its
`{{tags}}` become fields. The file is downloaded with the same SSRF protections and limits, and the tool result
lists the created roles and fields. Images are still accepted and create a template without fields.

## Requirements

DOCX conversion runs LibreOffice (`soffice`). The Docker image installs it by default
(`--build-arg INSTALL_LIBREOFFICE=false` leaves it out). Without it `/api/templates/docx` returns `501`.

## Limits and configuration

| Env variable                        | Default | Description                                    |
|-------------------------------------|---------|------------------------------------------------|
| `API_TEMPLATE_MAX_FILE_SIZE_MB`     | `20`    | Max size of each document                      |
| `API_TEMPLATE_MAX_REQUEST_SIZE_MB`  | `50`    | Max request body size (`413` above it)         |
| `API_TEMPLATE_MAX_PAGES`            | `500`   | Max pages per document                         |
| `API_TEMPLATE_CREATE_RATE_LIMIT`    | `30`    | Requests per user per minute (`429` above it)  |
| `DOCX_CONVERSION_TIMEOUT`           | `60`    | Seconds before LibreOffice is killed           |
| `DOCX_CONVERSION_CONCURRENCY`       | `2`     | Parallel LibreOffice processes per app process |
| `SOFFICE_PATH`                      |         | Custom path to the `soffice` binary            |

Per request: at most 10 documents, 500 fields, 100 areas per field and 20 roles.

## Security measures (OWASP API Security Top 10)

- **API1 Broken object level authorization**: templates are always created in the account of the API token owner;
  `external_id` upserts only match templates of that account and require `update` permission; folders are
  looked up within the account.
- **API2 Broken authentication**: `X-Auth-Token` (SHA-256 lookup, archived users rejected). Multipart requests
  must use the token header, not the session cookie, so cross-site form posts can't create templates.
- **API3 Broken object property level authorization**: strong params allow-list; `account_id`, `author_id`,
  `slug`, `source`, `archived_at`, etc. are ignored; field `preferences`/`validation` keys are allow-listed.
- **API4 Unrestricted resource consumption**: request, file, page, document, field and role limits; zip-bomb checks
  on DOCX (entry count and uncompressed size); LibreOffice timeout and concurrency cap; per-user rate limit.
- **API5 Broken function level authorization**: CanCanCan `create`/`update` checks on every request.
- **API7 Server side request forgery**: URL downloads are HTTPS on port 443 only, every resolved IP must be public
  (loopback, private, link-local/cloud metadata, CGNAT, multicast and reserved ranges are blocked), the connection
  is pinned to the checked IP (no DNS rebinding), redirects are re-checked, and size/timeouts are capped.
  DOCX files are stripped of external relationships, remote field codes (`INCLUDEPICTURE`, `INCLUDETEXT`, `LINK`,
  `DDE`, ...), `altChunk` and URL attributes before conversion, and LibreOffice runs with a throwaway profile
  that blocks untrusted links and macros. Macro-enabled documents are rejected.
- **API8 Security misconfiguration**: file types are checked by magic bytes, not by client-provided content type;
  XML is parsed without network access or DTD loading; error responses contain no internal details.
- **API10 Unsafe consumption of APIs**: downloaded and converted files are validated as PDF before processing.
