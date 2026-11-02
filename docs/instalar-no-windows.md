# Instalar o RIFFNEX pelo Windows (sem WSL)

Agora o app é compilado pelo GitHub, num Mac na nuvem. Você só baixa o arquivo `.ipa` e instala no iPhone com um programa do Windows.

Não precisa de WSL, regra de firewall, `portproxy` nem `USBMUXD_SOCKET_ADDRESS`.

## Uma vez só

1. Instale o **Dispositivos Apple** (Apple Devices) pela Microsoft Store, se ainda não tiver. Ele traz o driver do iPhone.
2. Instale o **Sideloadly**, de https://sideloadly.io. Ele assina o app com o seu Apple ID e instala pelo cabo.
3. Deixe o iPhone com o **Modo de Desenvolvedor** ligado. Ele já está, porque foi ativado nos testes anteriores.

> **Sobre o Apple ID:** o Sideloadly pede o seu Apple ID e senha, como o xtool pedia. Ele é gratuito, mas tem código fechado.
> - Se preferir, crie um Apple ID só para isso.
> - Nunca envie essas informações para o Claude.

## A cada atualização

1. **Baixe o `.ipa`:**
   - Abra https://github.com/thiagomendes/riffnex/actions/workflows/ipa.yml com o seu login do GitHub.
   - Clique na execução mais recente com o ✓ verde.
   - Em **Artifacts**, baixe **RIFFNEX-ipa**. Vem um `.zip` com o arquivo `RIFFNEX-xxxxxxx.ipa`.
2. Extraia o `.ipa` do `.zip`.
3. **Instale com o Sideloadly:**
   - Conecte o iPhone por cabo e desbloqueie a tela.
   - Abra o Sideloadly e arraste o `.ipa` para a janela.
   - Confira se o iPhone aparece em **iDevice** e preencha **Apple account**.
   - Clique em **Start** e digite a senha quando pedir.
4. **Na primeira vez**, no iPhone: Ajustes › Geral › **VPN e Gerenciamento de Dispositivo** › seu Apple ID › **Confiar**.

Os dados do app (músicas importadas e análises) continuam no iPhone ao instalar uma versão nova por cima.

> **Conta gratuita:** a assinatura vale **7 dias**. Depois disso, reinstale o mesmo `.ipa` pelo Sideloadly.

## E o WSL?

Pode continuar lá, sem uso para o RIFFNEX. Se quiser garantir que nada do RIFFNEX ficou mexendo na rede, rode no PowerShell como administrador:

```powershell
Remove-NetFirewallRule -DisplayName "WSL" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "RIFFNEX usbmuxd" -ErrorAction SilentlyContinue
netsh interface portproxy delete v4tov4 listenport=27015 listenaddress=172.21.144.1
netsh interface portproxy show all
```
