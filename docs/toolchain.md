# Como instalar o RIFFNEX no seu iPhone (Windows + WSL, sem Mac)

> Público: o dono do projeto. Última revisão: 2026-10-31.
> Ferramenta: [xtool](https://github.com/xtool-org/xtool) (MIT). Os passos seguem a documentação oficial dele ([Installation-Linux](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md)). Se algo divergir, vale o que está lá.

## Visão geral

```
Windows ──► WSL (Ubuntu) ──► Swift 6.4 + SDK do iOS (extraído do Xcode 27.1.xip) ──► xtool dev ──► iPhone (USB)
```

O código é compilado e testado automaticamente no GitHub Actions a cada push. No seu PC você só precisa compilar, assinar e instalar.

## Passo a passo (uma vez só)

1. **WSL com Ubuntu.** No PowerShell, como administrador:
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
   Reinicie se for solicitado e abra o “Ubuntu” pelo menu Iniciar.

2. **Swift 6.4 no Ubuntu.** Siga <https://swift.org/install/linux> (recomendado: instalador `swiftly`). Depois, confira:
   ```bash
   swift --version   # deve mostrar Swift version 6.4
   ```

3. **Dependências do xtool:**
   ```bash
   sudo apt-get update
   sudo apt-get install -y usbmuxd libfuse2 git
   ```
   O `libfuse2` permite rodar o xtool, que é distribuído como AppImage.

4. **xtool:**
   ```bash
   curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
   chmod +x xtool
   sudo mv xtool /usr/local/bin/
   xtool --help
   ```

5. **Xcode 27.1 (.xip):** baixe em <https://developer.apple.com/download/all/> com o seu Apple ID (é grátis) e salve em `Downloads`. No WSL, o arquivo aparece em `/mnt/c/Users/<seu-usuário>/Downloads/`.

6. **Configuração do xtool:**
   ```bash
   xtool setup
   ```
   - No login, escolha **Password** se você não tem a conta paga do Apple Developer Program. O próprio xtool sugere usar um Apple ID secundário, porque esse modo usa APIs privadas da Apple.
   - Quando ele pedir o Xcode, informe o caminho do `.xip`. O SDK ocupa cerca de 7 GB.
   - **Seu Apple ID e sua senha ficam só no seu PC.** Nunca envie essas informações para o Claude.

7. **iPhone conectado ao WSL por USB.** O WSL não enxerga USB sozinho. No PowerShell (administrador):
   ```powershell
   winget install usbipd
   usbipd list                       # anote o BUSID do "Apple Mobile Device" / iPhone
   usbipd bind --busid <BUSID>
   usbipd attach --wsl --busid <BUSID>
   ```
   Desbloqueie o iPhone e toque em **Confiar** quando ele perguntar. No Ubuntu, `xtool devices` deve listar o seu iPhone. Se aparecer `AFCClient.Error.muxError`, consulte a seção de solução de problemas da documentação do xtool.

8. **Modo de Desenvolvedor no iPhone:** Ajustes › Privacidade e Segurança › **Modo de Desenvolvedor** › ativar. O iPhone reinicia.

## Compilar e instalar

```bash
cd ~
git clone https://github.com/thiagomendes/riffnex.git
cd riffnex
git checkout claude/m0-foundation
xtool dev
```

Na primeira instalação, o iOS pode bloquear o app. Para liberar: Ajustes › Geral › **VPN e Gerenciamento de Dispositivo** › seu Apple ID › **Confiar**.

Para atualizar depois: `git pull && xtool dev`.

> **Conta gratuita:** o perfil de assinatura expira em **7 dias**. Depois disso o app para de abrir, e basta rodar `xtool dev` de novo.

## O que fazer no M0

1. Abra o RIFFNEX e toque em **Verificar este iPhone**.
2. Toque em **Executar todas as verificações**. Depois, toque em ▶︎ na linha “Reprodução” para ouvir a música de demonstração.
3. Opcional: **Escolher arquivo de áudio** e selecione uma música sua em MP3, M4A ou WAV.
4. Me envie prints da tela inteira, rolando até o final, incluindo o “Resultado bruto do Music Understanding”. Também serve o JSON pelo botão de compartilhar.

Se alguma etapa da instalação falhar, me envie a mensagem de erro completa do terminal.
