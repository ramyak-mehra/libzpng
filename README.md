# Libzpng

A toy png image decoder written in zig. I built this project as part of learning the language.

## Usage/Examples

Assuming you have zig installed on your system, you can run the following command to build the project

```bash
zig build -Doptimize=ReleaseSafe
```

The output binary will be inside ./zig-out/bin/libzpng

```bash
./zig-out/bin/libzpng {filepath.png}
```

**Note: It only support images with bit depth 8 and color type 2**

## Roadmap

- Add support for more color types.

- Add option to view the decoded image using raylib or directly opengl.

## Acknowledgements

- [PNG Wikipedia](https://en.wikipedia.org/wiki/PNG)
- [RFC 2083: PNG](https://datatracker.ietf.org/doc/html/rfc2083)
