# Teste no iPhone: M1, M2, M3 e instrumentos separados

Roteiro para testar tudo de uma vez no iPhone 14 Plus. A instalação é a mesma do `docs/toolchain.md`.

## 1. Preparar a conexão (Windows)

Você removeu a regra de firewall e o `portproxy` antes. Recrie os dois no **PowerShell como administrador**:

```powershell
New-NetFirewallRule -DisplayName "WSL" -Direction Inbound -InterfaceAlias "vEthernet (WSL (Hyper-V firewall))" -Action Allow
$myhost = (Get-NetIPAddress -InterfaceAlias "vEthernet (WSL (Hyper-V firewall))" -AddressFamily IPv4).IPAddress
netsh interface portproxy set v4tov4 listenport=27015 connectaddress=127.0.0.1 connectport=27015 listenaddress=$myhost
netsh interface portproxy show all
```

Deixe o app **Dispositivos Apple** aberto e o iPhone conectado por cabo e desbloqueado.

> Quando terminar de testar, pode remover os dois de novo (como você fez antes) para não interferir no outro projeto:
> `netsh interface portproxy delete v4tov4 listenport=27015 listenaddress=$myhost` e `Remove-NetFirewallRule -DisplayName "WSL"`.

## 2. Compilar e instalar (WSL)

```bash
export USBMUXD_SOCKET_ADDRESS="$(ip route list default | awk '{print $3}'):27015"
ideviceinfo | head -5     # deve mostrar dados do iPhone; se não, revise o passo 1
cd ~/riffnex
git fetch origin
git checkout claude/m2-analysis
git pull
xtool dev
```

Se o app não abrir porque o perfil expirou (conta gratuita, 7 dias), basta rodar `xtool dev` de novo.

## 3. O que testar

### M1: biblioteca e player
1. Na primeira abertura, aparece o onboarding (IMPORTE · DESCUBRA · TOQUE). Deslize ou toque em Continuar.
2. A música demo aparece na biblioteca. Abra-a.
3. **Player:**
   - Toque e pause.
   - Arraste na forma de onda para buscar uma posição.
   - Use os botões de ±5 s.
   - Mude a velocidade para 50% e 70%: o tom não pode mudar.
   - Ligue o loop e arraste as alças. A emenda do loop não pode ter clique nem pausa.
4. Bloqueie a tela: o áudio continua e os controles aparecem na tela bloqueada.
5. **Importe uma música sua** (app Arquivos → MP3/M4A/WAV):
   - Importe a mesma música duas vezes: deve aparecer o aviso de duplicata.
   - Um arquivo protegido (DRM) deve ser recusado com uma explicação.

### M2: análise
6. No player, toque em **Analisar**. Acompanhe as etapas:
   - Lendo o áudio
   - Tempo, tom e seções (sem barra de progresso, só o tempo decorrido)
   - Detectando notas (barra janela a janela)
   - Montando acordes e seções
7. Na demo, o esperado é **96 BPM**, tom **Em**, seções **A** (riff), **B** (acordes) e **Final**, e acordes **E5 G5 A5 C5 E5 G5 D5**.
8. Abra a **Visão geral**, tocando no resumo da análise: confira a qualidade, os motivos e a seção "Como foi feito", com os tempos de cada etapa.
9. Analise uma **música sua de cerca de 3 minutos** e anote o tempo total, que está em "Como foi feito". Esse é um dos números que o M2 precisa medir.
10. **Diagnóstico** (engrenagem na tela inicial) → "Velocidade da detecção de notas" → **Medir agora**:
    - Ele compara as combinações de processadores e escolhe a mais rápida para as próximas análises.
    - Mande um print do resultado.

### Novo: pista, fluxo simples e instrumentos separados
11. **Primeira análise:** a etapa **Separando instrumentos** é nova e a mais demorada. Na primeira vez o app também prepara o modelo de separação, que tem 74 MB.
    - Anote o tempo de cada etapa em "Como foi feito".
    - Se ficar lento demais, dá para desligar em Diagnóstico → "Separar instrumentos ao analisar".
12. **Pista (padrão):**
    - As cordas viram pistas, com o Mi grave à **direita**.
    - As notas descem com o número da casa e chegam na linha na hora de tocar.
    - A etiqueta azul mostra onde deve ficar a mão.
    - Tocar na pista pausa e explica a nota.
13. **Fluxo simples:**
    - Escolha **Riff** ou **Acordes**.
    - Toque num trecho (Parte A, B…): ele repete sozinho.
    - Escolha a velocidade (50/75/100%) e toque.
    - A contagem 1·2·3·4 vem ligada; desliga em **Mais**.
14. **Acordes:** aparece o desenho do acorde atual (na mesma orientação da pista), o próximo e uma barra até a troca.
15. **Instrumentos:**
    - Com a análise feita, aparece o botão **Instrumentos**.
    - Abaixe ou silencie cada instrumento enquanto toca.
    - Teste "Sem guitarra" (para tocar junto) e "Só guitarra".
    - **Confira se não há eco nem efeito de "phaser"**: as faixas precisam tocar perfeitamente juntas.
16. **Mais:** troque para Braço ou Tab, ligue o metrônome e confira se ele acompanha a música, inclusive em 50%.
17. **Diagnóstico → "Medir separação (demo)":** mande um print. Ele estima quanto tempo uma música de 4 minutos leva no seu iPhone.

## 4. O que me mandar
- Prints de qualquer erro, da Visão geral de uma música sua (qualidade e tempos) e dos dois testes de velocidade do Diagnóstico.
- Se a separação melhorou as notas e acordes de músicas com voz, comparando com antes.
- Como ficou o loop (emenda limpa?) e o metrônome (alinhado com a música?).
- Se algo travar: Diagnóstico → seção de registros → copie e cole o texto.
