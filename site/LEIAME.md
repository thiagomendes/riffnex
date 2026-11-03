# Site do RIFFNEX

Site estático de riffnex.tmdevlab.com: página inicial, ajuda (`suporte/`) e política de privacidade (`privacidade/`). Não precisa de build. Publique o conteúdo desta pasta como está.

- Links internos são relativos, então funciona em qualquer domínio ou subpasta.
- `CNAME` serve para hospedagens que usam esse arquivo para o domínio próprio. As outras ignoram.
- Fontes: Chakra Petch e Russo One, do Google Fonts.
- O app aponta para `https://riffnex.tmdevlab.com/privacidade/` e `https://riffnex.tmdevlab.com/suporte/`. Se o endereço mudar, troque também em `Sources/RiffnexApp/About/AboutView.swift` e em `docs/app-store.md`.
- Quando o app estiver na App Store, troque o botão "Em breve na App Store" em `index.html` pelo link da página do app.

## Publicação no Azure Static Web Apps

O workflow `.github/workflows/site.yml` publica esta pasta sempre que algo em `site/` muda (ou manualmente, em Actions › Site › Run workflow).

1. No portal do Azure, crie um **Static Web App** no plano **Free**. Em "Detalhes da implantação", escolha **Outro** (não ligue ao GitHub pelo portal, o workflow já faz isso).
2. Abra o recurso criado › **Gerenciar token de implantação** e copie o token.
3. No repositório, crie o segredo **`AZURE_STATIC_WEB_APPS_API_TOKEN`** com esse token.
4. Rode o workflow uma vez (Actions › Site › Run workflow).
5. Domínio: no recurso do Azure › **Domínios personalizados** › Adicionar › `riffnex.tmdevlab.com`. No DNS do tmdevlab.com, crie um registro **CNAME** `riffnex` apontando para o endereço padrão do app (algo como `nome-aleatorio.azurestaticapps.net`). O Azure valida e emite o certificado HTTPS sozinho.

`staticwebapp.config.json` define a página 404, barra no fim dos endereços e cabeçalhos de segurança.

## SEO

Já está no site:
- Título e descrição únicos por página, endereço canônico, `robots.txt` e `sitemap.xml`.
- Imagem de compartilhamento (`assets/og-image.png`, 1200×630) para WhatsApp, redes e buscadores.
- Dados estruturados (schema.org): `SoftwareApplication` e `WebSite` na página inicial, `FAQPage` na ajuda. Eles permitem que o Google mostre o app e as perguntas em destaque.
- A página 404 não é indexada.

O que vale fazer depois de publicar:
1. **Google Search Console**: adicione a propriedade `riffnex.tmdevlab.com` (verificação por registro TXT no DNS), envie `https://riffnex.tmdevlab.com/sitemap.xml` e peça a indexação da página inicial.
2. **Bing Webmaster Tools**: dá para importar direto do Search Console.
3. Quando o app estiver na App Store, coloque na página inicial a meta `<meta name="apple-itunes-app" content="app-id=SEU_ID">`, que mostra o banner nativo da loja no Safari do iPhone, e troque o botão "Em breve" pelo link da loja.
4. Links de fora ajudam muito: o próprio www.tmdevlab.com apontando para o RIFFNEX já é um bom começo.
