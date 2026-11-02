# RIFFNEX pelo TestFlight

Com a conta paga do Apple Developer Program, o GitHub compila o app e o envia sozinho para o TestFlight. Você instala e atualiza pelo app **TestFlight** no iPhone, sem cabo e sem o limite de 7 dias. Cada versão vale 90 dias.

> **Segurança:** os dados abaixo (Key ID, Issuer ID, o arquivo `.p8`, Team ID) vão **só** para os segredos do GitHub.
> - Não mande nenhum deles para o Claude, nem em chat ou print.
> - O arquivo `.p8` é uma chave. Guarde-o num lugar seguro ou apague depois de colar no GitHub.

## Uma vez só (uns 15 minutos)

### 1. Registrar o identificador do app
1. Entre em https://developer.apple.com/account › **Certificates, IDs & Profiles** › **Identifiers** › **+**.
2. Escolha **App IDs** › **App** › Continue.
3. Preencha:
   - **Description:** RIFFNEX
   - **Bundle ID:** escolha **Explicit** e digite exatamente `com.thiagomendes.riffnex`
4. Não precisa marcar nenhuma capability. Clique em **Continue** e depois em **Register**.

### 2. Criar o app no App Store Connect
1. Entre em https://appstoreconnect.apple.com › **Apps** › **+** › **Novo app**.
2. Preencha:
   - Plataforma: **iOS**
   - Nome: **RIFFNEX** (se estiver em uso por outro app, use algo como "RIFFNEX Guitar"; o nome no iPhone continua RIFFNEX)
   - Idioma principal: **Português (Brasil)**
   - ID do pacote: `com.thiagomendes.riffnex`
   - SKU: `riffnex`
   - Acesso: **Acesso total**

### 3. Criar a chave de API
1. No App Store Connect, vá em **Usuários e Acesso** › aba **Integrações** › **Chaves da API do App Store Connect**.
2. Na primeira vez, clique em **Solicitar acesso** e aceite.
3. Clique em **Gerar chave de API** (ou **+**):
   - Nome: `GitHub RIFFNEX`
   - Acesso: **Admin**
   - O Admin é necessário porque o CI usa os certificados de distribuição gerenciados pela Apple. Assim nenhum certificado fica guardado no GitHub.
4. Anote o **ID da chave** (Key ID) e o **ID do emissor** (Issuer ID), que fica no topo da página.
5. Clique em **Baixar chave de API**. Ela só pode ser baixada **uma vez**: vem um arquivo `AuthKey_XXXXXXXXXX.p8`.

### 4. Descobrir o Team ID
Está em https://developer.apple.com/account › **Membership details** › **Team ID**. São 10 letras e números.

### 5. Guardar os 4 segredos no GitHub
Vá em https://github.com/thiagomendes/riffnex › **Settings** › **Secrets and variables** › **Actions** › **New repository secret**. Crie um por um, com estes nomes exatos:

| Nome | Valor |
|---|---|
| `ASC_KEY_ID` | o ID da chave (passo 3) |
| `ASC_ISSUER_ID` | o ID do emissor (passo 3) |
| `ASC_KEY_P8` | o conteúdo inteiro do arquivo `.p8`. Abra no Bloco de Notas e copie tudo, inclusive as linhas `-----BEGIN PRIVATE KEY-----` e `-----END PRIVATE KEY-----` |
| `APPLE_TEAM_ID` | o Team ID (passo 4) |

### 6. Disparar o primeiro envio
1. O envio roda sozinho a cada atualização do app na branch `claude/m2-analysis`. Para disparar à mão, abra **Actions** › **TestFlight** › **Run workflow**.
   - O botão **Run workflow** só aparece se o workflow estiver na branch padrão do repositório.
   - Para ter o botão, mude a branch padrão em **Settings** › **General** › **Default branch**.
2. Leva uns 10 minutos. Me avise quando terminar, com ✓ verde ou com ✗. Se der ✗, eu leio o log e corrijo; não precisa me mandar nada.

### 7. No iPhone
1. Instale o app **TestFlight**, da Apple, pela App Store.
2. No App Store Connect › seu app › **TestFlight**:
   - Em **Testes internos**, crie um grupo (por exemplo, "Eu").
   - Adicione o seu usuário.
   - Marque **Distribuição automática**, se aparecer.
3. Quando a versão terminar de ser processada (10 a 30 minutos), ela aparece no TestFlight do iPhone. Toque em **Instalar**.

Na primeira versão, a Apple pode pedir para responder a pergunta de criptografia. O app já declara que não usa criptografia especial, então normalmente ela não aparece.

## Depois disso

- **Novas versões:** cada mudança que eu enviar gera uma versão nova no TestFlight automaticamente. É só tocar em **Atualizar** no TestFlight.
- **Seus dados:** as músicas importadas e as análises continuam no iPhone entre versões do TestFlight.
  - Na **primeira** instalação pelo TestFlight, pode ser que o iPhone peça para apagar o RIFFNEX instalado antes pelo xtool ou Sideloadly, porque ele foi assinado com outra conta.
  - Se pedir, apague; aí você importa suas músicas de novo, só dessa vez.
- **Rede do Windows:** não precisa mais do WSL, do firewall nem do `portproxy` para o RIFFNEX.
