# Compilar o `client` dentro do WSL2

O `client` é o jogo, escrito em C++. Ele é um programa de Windows: o resultado da compilação é um
`.exe`. Mas **você não precisa do Windows para compilá-lo**. Dá para fazer tudo dentro do WSL2, sem
Visual Studio e sem sair do Linux.

O truque é o [msvc-wine](https://github.com/mstorsjo/msvc-wine). Ele baixa o compilador de verdade da
Microsoft — o mesmo que o Visual Studio usa — e roda ele em cima do [Wine](https://www.winehq.org/), que
é um programa que sabe executar programas de Windows no Linux. Não é uma imitação do compilador: é o
compilador original, só que rodando em outro lugar.

## Antes de começar, saiba disto

- **Vai ocupar uns 4,5 GB no disco.** O download em si é menor, porque vem compactado. É uma vez
  só por máquina, mas é grande.
- **Você aceita a licença do Visual Studio** ao baixar. A licença não deixa a gente redistribuir o que
  foi baixado, então **não dá para colocar isso numa imagem de CI ou de Docker compartilhada**. Cada
  pessoa baixa a sua própria cópia.
- **Isto é opcional.** O servidor e o site funcionam sem nada disso. Só faça se você for mexer no jogo.
- **Depois de instalar, o `yarn dev` passa a compilar o jogo junto.** Se você não quiser isso, leia
  "Rodando junto com o resto" mais abaixo.

## O passo a passo

Você faz isto uma vez por máquina.

### 1. Instale os programas do Linux

```bash
sudo apt-get install -y wine64 python3 msitools ca-certificates winbind
```

O `winbind` parece opcional, mas não é: sem ele o compilador quebra na hora de gerar os arquivos de
debug, com a mensagem `fatal error C1902: Program database manager mismatch`.

### 2. Baixe o msvc-wine

```bash
git clone https://github.com/mstorsjo/msvc-wine ~/msvc-wine
```

### 3. Baixe o compilador da Microsoft

São **dois** comandos, e os dois são necessários.

O primeiro baixa o compilador na versão que o jogo pede (a `v142`, do Visual Studio 2019):

```bash
~/msvc-wine/vsdownload.py --accept-license --major 16 --msvc-version 16.11 --dest ~/msvc
```

O segundo baixa o **MSBuild**, que é o programa que lê o arquivo `TM.sln` e manda compilar. Ele não vem
no pacote do Visual Studio 2019, só no do 2022 — por isso o `--major 17`. Todos aqueles `no` são para não
baixar o resto do 2022 de novo; só o MSBuild interessa. São 32 MB, não mais 4,5 GB:

```bash
~/msvc-wine/vsdownload.py --accept-license --major 17 \
  --with-default no --with-workload no --with-msvc no --with-sdk no \
  --with-atl no --with-dia no --with-devcmd no --with-msbuild yes \
  --dest ~/msvc
```

Repare que os dois usam o mesmo `--dest ~/msvc`. É de propósito: as duas partes moram na mesma pasta.

### 4. Arrume o que foi baixado

```bash
~/msvc-wine/install.sh ~/msvc
```

### 5. Instale o wine-mono

O MSBuild é escrito em C#, então ele precisa de um programa que saiba rodar C#. Esse programa é o
wine-mono.

**Preste atenção no `mv` do final.** O Wine só procura o wine-mono num lugar exato,
`c:\windows\mono\mono-2.0`. Se a pasta ficar com o nome original (`wine-mono-9.4.0`), o MSBuild morre
sem dizer nada — sai com erro e sem escrever nenhuma mensagem:

```bash
cd /tmp
curl -LO https://dl.winehq.org/wine/wine-mono/9.4.0/wine-mono-9.4.0-x86.tar.xz
mkdir -p ~/.wine/drive_c/windows/mono
tar -xJf wine-mono-9.4.0-x86.tar.xz -C ~/.wine/drive_c/windows/mono
mv ~/.wine/drive_c/windows/mono/wine-mono-9.4.0 ~/.wine/drive_c/windows/mono/mono-2.0
```

### 6. Teste

Na raiz do projeto:

```bash
yarn build:app:client
```

Se deu certo, o jogo aparece em `packages/apps/client/Release/TMProject.exe`. Compilar tudo do zero
leva uns 25 segundos; depois disso, quando você muda um arquivo só, leva uns 8 segundos.

A primeira vez que você rodar pode demorar bem mais do que isso, e não é problema: o Wine ainda está
montando o ambiente dele. Da segunda vez em diante o tempo cai.

## Como usar no dia a dia

```bash
yarn build:app:client   # compila uma vez
yarn dev:app:client     # fica vigiando e recompila quando você salva um arquivo
```

O `yarn dev:app:client` usa o `nodemon`, o mesmo programa que vigia o servidor em Rust. Ele olha a pasta
`packages/apps/client/Projects` e recompila quando um arquivo `.cpp`, `.h`, `.rc`, `.vcxproj` ou `.sln`
muda.

**Lembre-se de que o `client` é um submódulo**: as mudanças no jogo são escritas no repositório
`w2-client`, não aqui. Aqui você só compila. Veja a seção "Atualizar o jogo (`client`)" do README.

### Rodando junto com o resto

O `yarn dev` liga o servidor, o site **e** o compilador do jogo ao mesmo tempo. Duas consequências:

- Se o C++ não compilar, o `yarn dev` derruba o servidor e o site junto — é o
  `--kill-others-on-fail` fazendo o trabalho dele.
- Quem não instalou o compilador não consegue mais rodar `yarn dev` inteiro. Use `yarn dev:app:server` e
  `yarn dev:app:web` separados.

Se você preferir que o jogo **não** entre no `yarn dev`, renomeie o script `dev:app:client` no
`package.json` da raiz para qualquer nome que não comece com `dev:` — por exemplo `watch:app:client`. O
`yarn dev` monta a lista dele com o padrão `yarn:dev:*`, então o nome é a única coisa que decide.

## Coisas que podem te morder

**Só compile em `Release`.** O `TMProject.vcxproj` monta a lista de pastas de cabeçalhos numa ordem
diferente em cada configuração, e só a `Release|Win32` está numa ordem que funciona. Na `Debug|x64` as
pastas do DirectX de 2002 vêm primeiro e atropelam as do Windows; o `basetsd.h` antigo não tem o
`PVOID64`, e aí o `<windows.h>` inteiro para de compilar com um erro que parece não ter nada a ver:

```
fileapi.h(1212): error C2146: syntax error: missing ')' before identifier 'aSegmentArray'
```

Isso é um problema do `w2-client`, não daqui. Se precisar de `Debug|x64`, arrume a ordem lá primeiro.

**A recompilação automática pode não perceber algumas mudanças.** Um dos pacotes que o MSBuild usa para
saber o que mudou (`Microsoft.Build.FileTracker`) não é instalado por este caminho. Se você salvar um
arquivo e o `.exe` não mudar, force uma compilação completa apagando a pasta
`packages/apps/client/Projects/TMProject/Release`.

**Não precisa de Visual Studio, nem de Windows, nem de `/mnt/c`.** O jogo compila direto na pasta do
Linux (`ext4`). Se você tentar o contrário — deixar o código no Linux e chamar o MSBuild do Windows por
`\\wsl.localhost\` — não funciona, porque o Linux diferencia maiúsculas de minúsculas e o compilador da
Microsoft não. O Wine resolve isso sozinho. O porquê disso está em
[`docs/researchs/wsl2-client-build-watcher.md`](./researchs/wsl2-client-build-watcher.md).

## Se der errado

| O que aparece | O que é |
| --- | --- |
| `wine: failed to open ".../MSBuild/Current/Bin/amd64/MSBuild.exe"` | Faltou o passo 3, segundo comando (o MSBuild do `--major 17`). |
| Sai com erro e **nenhuma mensagem** | Faltou o wine-mono, ou a pasta dele está com o nome errado. Veja o passo 5. |
| `err:mscoree:CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed` | O mesmo problema, só que com o Wine falando. |
| `error MSB4019: The imported project "...\v170\Microsoft.Cpp.Default.props" was not found` | O `scripts/build-client.sh` não está sendo usado. Ele existe justamente para arrumar isto. |
| `fatal error C1902: Program database manager mismatch` | Faltou o `winbind` no passo 1. |

## Onde fica o quê

- `scripts/build-client.sh` — o script que compila. Se o seu toolchain não estiver em `~/msvc`, exporte
  `MSVC_ROOT` apontando para onde ele está.
- `package.json` da raiz — os scripts `build:app:client` e `dev:app:client`.
- `docs/researchs/wsl2-client-build-watcher.md` — a pesquisa que levou a esta receita, com as medições e
  o que foi testado ou não. Leia se algo aqui não bater com a realidade.
