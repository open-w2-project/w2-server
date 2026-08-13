# W2 Server

Este repositório é um servidor para o jogo **With Your Destiny (WYD)**, junto com um site para acompanhá-lo.

Ele guarda três pastas dentro de `packages/apps/`:

- **`server`** — o servidor do jogo. Ele é escrito em Rust. É o programa que fica ligado esperando os jogadores se conectarem.
- **`web`** — o site. Ele é escrito em TypeScript com Next.js e React. É a parte que você abre no navegador.
- **`client`** — o jogo que o jogador abre no computador dele. Ele é escrito em C++ e mora em outro repositório ([w2-client](https://github.com/open-w2-project/w2-client)); aqui ele entra como um *submódulo* do Git. Você pode mudar o código do jogo daqui de dentro, mas o commit dessa mudança vai para o outro repositório, não para este. Ele tem o próprio README também.

O texto abaixo explica como colocar tudo isso para rodar na sua máquina.

## Instalação

### O que você precisa ter antes

| Ferramenta | Versão | Para que serve |
| --- | --- | --- |
| Node.js | `v24.18.1` (está escrito no arquivo `.nvmrc`) | roda o site e os comandos do projeto |
| Yarn | 1 (o clássico) | baixa as bibliotecas do Node.js |
| Rust | 1.97 ou mais novo, com a edição 2024 | compila e roda o servidor |
| Git | qualquer versão recente | baixa o código |

Para compilar a pasta `client` você precisa de mais coisas, mas **não precisa do Windows**: dá para compilar o jogo dentro do próprio WSL2. Isso é opcional — o servidor e o site funcionam sem ela. O passo a passo está em [`docs/setup-client-wsl2.md`](./docs/setup-client-wsl2.md).

### 1. Baixe o código

O `client` é um submódulo. Submódulo é um repositório que mora dentro de outro. Ele não vem sozinho: você precisa pedir.

```bash
git clone --recurse-submodules git@github.com:open-w2-project/w2-server.git
```

Se você já tinha clonado o repositório sem o submódulo, rode isto dentro da pasta do projeto:

```bash
git submodule update --init
```

### 2. Instale as bibliotecas do Node.js

Na raiz do projeto:

```bash
yarn install
```

Um comando só. Ele instala as bibliotecas das duas pastas (`server` e `web`) de uma vez, porque o projeto usa *workspaces* do Yarn.

As bibliotecas do Rust não precisam de comando: o `cargo` baixa tudo sozinho na primeira vez que você rodar o servidor.

## Como usar

### Rodar tudo de uma vez

Na raiz do projeto:

```bash
yarn dev
```

Isso liga o servidor, o site e a compilação do jogo ao mesmo tempo. Se um dos três quebrar, os outros também param.

A parte do jogo só funciona se você tiver feito o [passo a passo do `client`](./docs/setup-client-wsl2.md). Se você não fez, rode as partes separadas.

O site fica em <http://localhost:3000>.

### Rodar só uma parte

```bash
yarn dev:app:server   # só o servidor do jogo
yarn dev:app:web      # só o site
yarn dev:app:client   # só o jogo (precisa do passo a passo do client)
```

Os três recarregam sozinhos quando você salva um arquivo:

- o servidor é vigiado pelo `nodemon`, que olha `Cargo.toml` e a pasta `src` e roda `cargo run` de novo;
- o site usa o modo `next dev --turbo`, que já recarrega sozinho;
- o jogo é vigiado pelo `nodemon` também, que olha a pasta `Projects` do `client` e compila de novo quando um arquivo `.cpp`, `.h`, `.rc`, `.vcxproj` ou `.sln` muda.

Você também pode entrar na pasta e usar as ferramentas direto:

```bash
cd packages/apps/server && cargo run    # roda o servidor
cd packages/apps/web && yarn dev        # roda o site
```

### Compilar o jogo sem ficar vigiando

```bash
yarn build:app:client
```

Isso compila uma vez e para. O jogo pronto aparece em `packages/apps/client/Release/TMProject.exe`.

### Mudar o jogo e o servidor juntos

Muita mudança mexe nos dois lados ao mesmo tempo: o jogo manda uma informação nova, e o servidor precisa entender essa informação. Os dois moram em repositórios diferentes, então isso vira **três commits**, sempre nesta ordem:

1. o commit do jogo, lá no repositório `w2-client`;
2. o commit do servidor ou do site, aqui;
3. o commit do "endereço" novo — aquele que diz qual versão do jogo este repositório usa.

A ordem importa. Se o endereço apontar para uma versão do jogo que ninguém consegue baixar, o repositório quebra para todo mundo que clonar.

Quem faz isso na ordem certa é o comando `/w2-commit`. Ele também escreve as mensagens dos commits, que seguem padrões diferentes em cada repositório.

Antes de começar, o jogo precisa estar num *branch* com nome. Você escolhe o nome:

```bash
git -C packages/apps/client switch -c meu-branch
```

### Pegar uma versão nova do jogo

Se você não mudou nada no jogo e só quer a versão mais nova que saiu lá no `w2-client`:

```bash
git -C packages/apps/client status          # confira que não há nada seu por salvar
git submodule update --remote packages/apps/client
git add packages/apps/client
git commit -m "chore(client): bump the pin"
```

O primeiro comando é importante. O `--remote` troca a versão do jogo que está na sua máquina, e ele para no meio se encontrar mudança sua ainda não commitada. Confira antes para não descobrir isso no meio do caminho.

### O que tem dentro de cada pasta

```
w2-server/
├── packages/apps/server/   # servidor em Rust (binário w2-server)
│   ├── Cargo.toml
│   └── src/main.rs
├── packages/apps/web/      # site em Next.js
│   ├── package.json
│   └── src/pages/          # as páginas do site
├── packages/apps/client/   # submódulo: o jogo em C++ (outro repositório)
├── docs/                   # explicações escritas à mão
│   ├── setup-client-wsl2.md
│   └── researchs/          # pesquisas, com as medições
├── scripts/
│   └── build-client.sh     # compila o jogo
├── openspec/               # as especificações do projeto
│   ├── config.yaml
│   ├── changes/            # mudanças propostas
│   └── specs/              # o que já está acordado
├── Cargo.toml              # workspace do Rust
└── package.json            # workspace do Yarn
```

### As bibliotecas usadas

**Site (`packages/apps/web`)** — o que ele usa para funcionar:

| Biblioteca | Versão |
| --- | --- |
| `next` | 16.3.0 |
| `react` | 19.2.8 |
| `react-dom` | 19.2.8 |

E o que ele usa só na hora de programar: `typescript` 6.0.3, `eslint` 10.8.1, `typescript-eslint` 8.67.0, `eslint-plugin-react` 7.37.5, `@eslint/js` 10.0.1, `globals` 17.11.0, `prettier` 3.9.6, `@types/node` 24.13.3, `@types/react` 19.2.18, `@types/react-dom` 19.2.4.

**Servidor (`packages/apps/server`)** — hoje ele não usa nenhuma biblioteca do Rust; a lista `[dependencies]` do `Cargo.toml` está vazia. Para o recarregamento automático ele usa o `nodemon` 3.1.14.

**Raiz do projeto** — `@fission-ai/openspec` 1.8.0 (organiza as especificações), `concurrently` 10.0.4 (liga as três partes juntas) e `nodemon` 3.1.14 (vigia a pasta do jogo).

### As especificações

A pasta `openspec/specs/` guarda o que já foi acordado sobre o comportamento do projeto. **Hoje ela está vazia**: ainda não existe nenhuma especificação acordada, e também não há nenhuma mudança em andamento em `openspec/changes/`.

Uma coisa importante de saber: essa pasta descreve o que foi **combinado**, não o que já foi **construído**. Ver algo escrito lá não quer dizer que o código existe.

## Licença

Este projeto usa a licença **Apache 2.0**. O texto completo está no arquivo [`LICENSE`](./LICENSE).

A pasta `packages/apps/client` é um repositório separado e tem a própria licença: o código dela está sob a **GNU GPL v3**, e não sob a Apache 2.0 do resto daqui. Por causa disso, a gente nunca copia código de lá para cá — nem um trecho, nem uma `struct`. Ler o código do jogo para saber como ele conversa com o servidor é o uso normal; copiar não é.

Ela também é uma descompilação do cliente de With Your Destiny, feita só para estudo; os direitos do jogo são da Hanbitsoft. Leia o README de dentro dela antes de usar aquele código.
