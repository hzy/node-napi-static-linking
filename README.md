# N-API 静态链接实验笔记

在有些场景下，我们希望将自己的 CLI 打包成一个 single binary 发布，但是由于使用了 N-API 扩展（`.node` 文件），传统的打包方案基本都是采用自解压或者类似的方式，而 Node.js 的 SEA（Single Executable Application）则完全不支持打包 `.node` 文件，而是需要外置它。

本文讲了一种不同的思路：**把 N-API addon 编译为静态库（`.a`），在编译 Node.js 时直接链接进二进制**，让 addon 成为 Node.js 的一部分，不再需要 `.node` 文件。这样配合 SEA 就可以实现真正的 single binary 发布。

## 核心思路

Node.js 内部有一套 **linked binding** 机制——V8 的内置模块就是通过这个注册的。我们要做的就是把一个标准 N-API addon "伪装"成 Node.js 的 linked binding：

```
标准 N-API addon (.node)                     linked binding（编译进 node 二进制）
─────────────────────────                     ─────────────────────────────────
dlopen() 加载                                  编译时静态链接
require('xxx.node')                            process._linkedBinding('name')
导出符号: napi_register_module_v1              同一个符号，通过 wrapper 桥接注册
```

**对 addon 源码的要求：零修改。** 同一份 C++ 代码，用同一套 node-gyp + node-addon-api，只是在 `binding.gyp` 里多加一个 `"type": "static_library"` 的 target 就行。

## 要解决的问题

### 1. 符号注册方式不同

N-API addon 导出的是 `napi_register_module_v1`（一个 C 函数），而 Node.js linked binding 需要的是一个 V8 context-aware init 函数，通过 `node_module` 结构体注册。

解决方案：自动生成一个 C++ wrapper，用 `napi_module_register_by_symbol()` 把 N-API init 桥接到 linked binding 注册体系：

```cpp
// 自动生成的 wrapper（简化版）
extern "C" napi_value napi_register_module_v1__my_addon(napi_env, napi_value);

static void InitMyAddon(v8::Local<v8::Object> exports, ...) {
  napi_module_register_by_symbol(exports, module, context,
      napi_register_module_v1__my_addon,  // 桥接到 N-API init
      NODE_API_DEFAULT_MODULE_API_VERSION);
}

// 注册为 linked binding，C constructor 保证在 main 之前执行
static node::node_module mod = { ..., InitMyAddon, "my_addon", ... };
NODE_C_CTOR(reg) { node_module_register(&mod); }
```

### 2. 多个 addon 的符号冲突

每个 N-API addon 都导出同名的 `napi_register_module_v1`。链接两个 `.a` 就会 multiple definition。

解决方案：用 `objcopy --redefine-sym` 在链接前给每个 `.a` 的符号加上唯一后缀：

```bash
objcopy --redefine-sym napi_register_module_v1=napi_register_module_v1__hello  libhello.a
objcopy --redefine-sym napi_register_module_v1=napi_register_module_v1__world  libworld.a
```

### 3. 集成到 Node.js 构建系统

我们给 Node.js 的 `configure.py` 加了一个 `--link-napi-addon` flag，让整个过程自动化：

```bash
./configure --link-napi-addon my_addon:/path/to/libmy_addon.a
```

configure 阶段自动完成：
1. 复制 `.a` 到 staging 目录
2. `objcopy --redefine-sym` 重命名符号
3. 生成 C++ wrapper 源码
4. 把路径写入 `config.gypi`，GYP 自动编译 wrapper、链接 `.a`

对 Node.js 的修改只有 +40 行（一个 patch），涉及三个文件：

| 文件 | 改动 |
|------|------|
| `configure.py` | +9 行 flag 定义，+20 行处理逻辑 |
| `node.gyp` | +5 行变量声明和引用 |
| `tools/link_napi_addons.py` | 新增，~110 行，objcopy + 代码生成 |

## 仓库结构

```
.
├── build.sh                     # 一键构建脚本
├── patches/
│   └── 0001-feat-add-...patch   # 对 Node.js 的 patch（git format-patch 格式）
├── simple-napi/                 # 示例 N-API addon
│   ├── src/addon.cpp            # hello / add / fibonacci
│   ├── binding.gyp              # 两个 target：.node 和 .a
│   ├── lib/index.js
│   └── test.js
├── deps/
│   └── node/                    # Node.js v25.9.0（git submodule, shallow）
└── .github/
    └── workflows/build.yml      # CI
```

## 如何复现

```bash
git clone --recursive https://github.com/hzy/node-napi-static-linking.git
cd node-napi-static-linking
./build.sh
```

`build.sh` 会依次执行：

1. 拉取 Node.js 子模块（`depth=1`，约 200MB）
2. 应用 patch（幂等，已应用则跳过）
3. 编译 `simple-napi` 的静态库（`npm install` + `node-gyp rebuild`）
4. `configure --link-napi-addon simple_napi:...a`
5. `make -j$(nproc)`（首次约 20-40 分钟）
6. 输出 `build/node`，运行 smoke test

构建完成后：

```bash
./build/node -e "const m = process._linkedBinding('simple_napi'); console.log(m.hello())"
# Hello from N-API!

./build/node -e "const m = process._linkedBinding('simple_napi'); console.log(m.add(3, 4))"
# 7

./build/node -e "const m = process._linkedBinding('simple_napi'); console.log(m.fibonacci(50))"
# 12586269025
```

这个 `build/node` 就是一个标准的 Node.js 二进制，只是多了一个内置的 linked binding。可以在此基础上用 SEA 把你的 JS 入口也打包进去，得到一个真正的 single binary。

## 如何用到自己的项目

### 第一步：让你的 addon 能编译成静态库

在 `binding.gyp` 里加一个 target，和原有的 `.node` target 共享同一份源码，只是 `type` 改为 `static_library`：

```json
{
  "targets": [
    {
      "target_name": "my_addon",
      "sources": ["src/addon.cpp"],
      "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"]
    },
    {
      "target_name": "my_addon_static",
      "type": "static_library",
      "sources": ["src/addon.cpp"],
      "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"]
    }
  ]
}
```

`npx node-gyp rebuild` 后会同时产出 `my_addon.node` 和 `my_addon_static.a`。

### 第二步：准备 Node.js 源码并应用 patch

```bash
git clone --depth 1 --branch v25.9.0 https://github.com/nodejs/node.git
cd node
git am /path/to/patches/0001-feat-add-link-napi-addon-configure-flag.patch
```

### 第三步：configure + make

```bash
./configure \
  --link-napi-addon "my_addon:/path/to/my_addon_static.a" \
  --without-npm

make -j$(nproc)
```

如果有多个 addon：

```bash
./configure \
  --link-napi-addon "addon_a:/path/to/liba.a" \
  --link-napi-addon "addon_b:/path/to/libb.a" \
  --without-npm
```

### 第四步：在 JS 里使用

```js
// 之前：
const addon = require('./build/Release/my_addon.node');

// 现在：
const addon = process._linkedBinding('my_addon');
```

可以用一个运行时判断来兼容两种模式：

```js
let addon;
try {
  addon = process._linkedBinding('my_addon');
} catch {
  addon = require('./build/Release/my_addon.node');
}
```

## 局限

- **仅 Linux**：`objcopy --redefine-sym` 是 GNU binutils 工具，macOS/Windows 需要不同方案（`llvm-objcopy`、`lib.exe`）
- **需要从源码编译 Node.js**：不可避免，因为要链接进二进制
- **`process._linkedBinding()` 是内部 API**：不是公开稳定接口，但机制本身是 Node.js 核心架构的一部分，不太可能消失
- **调试复杂度**：addon crash 时的 stack trace 和动态加载时略有不同

## License

MIT
