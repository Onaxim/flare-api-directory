# evm-abi-viewer

## Recommended IDE Setup

[VSCode](https://code.visualstudio.com/) + [Volar](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur) + [TypeScript Vue Plugin (Volar)](https://marketplace.visualstudio.com/items?itemName=Vue.vscode-typescript-vue-plugin).

## Customize configuration

See [Vite Configuration Reference](https://vitejs.dev/config/).

## Project Setup

```sh
npm install
```

### Compile and Hot-Reload for Development

```sh
npm run dev
```

### Compile and Minify for Production

```sh
npm run build
```

### Adding new ABI's

1. Import ABI JSON into network specific folder (`./src/artifacts/<NETWORK>/`)
   - Follow capitaliztion naming convention (`my new contract` should be `MyNewContract`)
2. Add a new entry into the `meta.json` file for the file following the template (all fields are optional):

```
  "TEMPLATE": {
    "address": "",
    "description": "",
    "comments": {
      "write": {
        "METHOD_NAME": "Description"
      },
      "read": {
        "METHOD_NAME": "Description"
      },
      "event": {
        "EVENT_NAME": "Description"
      }
    }
  },
```

3. Edit network specific components (`./src/components/<NETWORK>AbiList.vue`) adding:
   - Import for the ABI `import <ABI_NAME>Abi from "../artifacts/<NETWORK>/<ABI_NAME>.json";`
   - Append to the `abiList` array the import and abi name: `{ name: "<ABI_NAME>", file: <ABI_NAME> }`

### Todo:

- View/Download ABI code
- Link each ABI to GitLab implementation
- Categorise each contract (ie. FTSO system contracts)

### Contributors:

- Tim Rowley | [Twitter](https://twitter.com/timrowley_au)
