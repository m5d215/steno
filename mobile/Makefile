PROJECT := steno-mobile.xcodeproj
SCHEME  := steno-mobile

.PHONY: gen build sim open clean

# project.yml から .xcodeproj を生成(SSOT は project.yml)。
gen:
	xcodegen generate

# シミュレータ向けにビルド(署名不要。コンパイルが通るかの確認用)。
build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
	    -derivedDataPath DerivedData build

# Xcode で開く(実機ビルド/署名は Xcode で Team を設定して行う)。
open: gen
	open $(PROJECT)

clean:
	rm -rf DerivedData $(PROJECT) Generated
