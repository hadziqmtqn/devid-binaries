# imagick: ImageMagick for PHP (Intervention Image, Spatie Image, CodeIgniter 4, WordPress).
# ImageMagick and its format libraries are built static into the .so (Devid E1, D-024).
VERSION=3.8.1
URL="https://pecl.php.net/get/imagick-$VERSION.tgz"
SHA256=3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee
LICENSE=PHP-3.01
LICENSE_FILES=(LICENSE)
# The format libraries spc builds for ImageMagick (its imagick recipe minus ImageMagick itself).
IM_LIBS=zlib,libjpeg,brotli,libpng,libwebp,libjxl,freetype,libiconv,libtiff,libde265,libaom,libheif,bzip2,libxml2
SPC_LICENSES="$IM_LIBS"
# ImageMagick looks for policy.xml and type.xml here; Devid sets the variable for php-fpm and the CLI.
ENV_JSON='{"MAGICK_CONFIGURE_PATH": "etc"}'

# Pinned, because extensions/imagick/imagemagick-svg-url-fill.patch must apply to it. GitHub's tag
# archive is the source ImageMagick publishes (its releases carry no source tarball).
IM_VERSION=7.1.2-35
IM_URL="https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IM_VERSION.tar.gz"
IM_SHA256=40b6fefa88fe16ca5a4b3d3db5133eaebfb0157f21f98530bde8aec5dd5b0776
IM_PATCH="$RECIPES/imagick/imagemagick-svg-url-fill.patch"

build_imagemagick() {
  # The build root is cached between CI runs; rebuild only when the version or the patch changes.
  local stamp="$BR/lib/devid-imagemagick.stamp" want src
  want="$IM_VERSION $(shasum -a 256 "$IM_PATCH" | cut -c1-64)"
  [ "$(cat "$stamp" 2>/dev/null)" != "$want" ] || return 0
  fetch "$IM_URL" "$IM_SHA256" "$WORK/ext/downloads/ImageMagick-$IM_VERSION.tar.gz"
  src="$WORK/ext/src/ImageMagick"
  rm -rf "$src" && mkdir -p "$src" && tar -xzf "$WORK/ext/downloads/ImageMagick-$IM_VERSION.tar.gz" -C "$src" --strip-components 1
  patch -d "$src" -p1 --forward --batch < "$IM_PATCH" >/dev/null || {
    echo "FAIL: the SVG patch no longer applies to ImageMagick $IM_VERSION; drop it if ImageMagick/ImageMagick#9093 is fixed" >&2
    return 1
  }
  # spc's ImageMagick options, plus libxml2 for SVG (D-024). Delegates that are not built here are
  # off explicitly, so a library on the build machine can never slip in.
  (cd "$src" && run imagemagick-configure ./configure --enable-static --disable-shared --prefix="$BR" \
    --with-pic --enable-pic --disable-openmp --without-x --without-magick-plus-plus --without-perl \
    --with-bzlib --with-freetype --with-heic --with-jpeg --with-jxl --with-png --with-tiff --with-webp --with-xml --with-zlib \
    --without-djvu --without-dmr --without-fontconfig --without-gvc --without-jbig --without-lcms --without-lqr \
    --without-lzma --without-openexr --without-openjp2 --without-pango --without-raqm --without-raw \
    --without-zip --without-zstd \
    CC=clang CXX=clang++ "CFLAGS=-I$BR/include --target=$ARCH-apple-darwin -Os" \
    "CXXFLAGS=-I$BR/include --target=$ARCH-apple-darwin -Os" "LDFLAGS=-L$BR/lib" "LIBS=-liconv -lresolv" \
    "PKG_CONFIG=$(command -v pkg-config) --static" &&
    run imagemagick-make make -j"$(sysctl -n hw.ncpu)" &&
    run imagemagick-install make install)
  echo "$want" > "$stamp"
}

prepare() {
  spc_libs "$IM_LIBS"
  build_imagemagick
  ARGS+=(--with-imagick="$BR" "LIBS=$(pkg-config --static --libs MagickWand)")
}

stage_extra() {
  mkdir -p "$STAGE/etc"
  cp "$BR/etc/ImageMagick-7/policy.xml" "$STAGE/etc/"   # ImageMagick's default ("open") policy
  cp "$RECIPES/imagick/type.xml" "$STAGE/etc/"
  cp "$BR/share/doc/ImageMagick-7/LICENSE" "$STAGE/LICENSES/ImageMagick-LICENSE"
}

SMOKE="$(cat <<'PHP'
$formats = Imagick::queryFormats();
foreach (["JPEG", "PNG", "GIF", "WEBP", "AVIF", "HEIC", "JXL", "TIFF", "SVG"] as $f) check(in_array($f, $formats), "format $f");
$src = new Imagick();
$src->newPseudoImage(120, 80, "gradient:orange-navy");
foreach (["jpeg", "png", "gif", "webp", "avif", "jxl", "tiff"] as $fmt) {
    $im = clone $src; $im->setImageFormat($fmt);
    $back = new Imagick(); $back->readImageBlob($im->getImageBlob()); $back->thumbnailImage(60, 0);
    check($back->getImageWidth() === 60, "$fmt write, read, thumbnail");
}
// The SVG patch (ImageMagick/ImageMagick#9093): without it this gradient is black.
$svg = <<<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="200" y2="0"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs><rect width="200" height="100" fill="url(#g)"/></svg>
SVG;
$s = new Imagick(); $s->setBackgroundColor("white"); $s->readImageBlob($svg);
$l = $s->getImagePixelColor(5, 50)->getColor(); $r = $s->getImagePixelColor(194, 50)->getColor();
check($l["r"] > 200 && $l["b"] < 50 && $r["b"] > 200 && $r["r"] < 50, "SVG gradient");
// The default font comes from etc/type.xml.
$t = new Imagick(); $t->newImage(120, 40, "white");
$d = new ImagickDraw(); $d->setFontSize(20); $t->annotateImage($d, 5, 30, 0, "Devid");
check($t->getImageColors() > 1, "text with the default font");
PHP
)"
