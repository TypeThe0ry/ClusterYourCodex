import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, expectTypeOf, it } from "vitest";
import {
  DEFAULT_LOCALE,
  I18nProvider,
  LOCALE_STORAGE_KEY,
  type Locale,
  normalizeLocale,
  persistLocale,
  resolveInitialLocale,
  translate,
  type TranslationKey,
  useI18n,
} from "./i18n";

function memoryStorage(initial: Record<string, string> = {}) {
  const values = new Map(Object.entries(initial));
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => void values.set(key, value),
    value: (key: string) => values.get(key),
  };
}

describe("i18n", () => {
  it("normalizes supported browser language variants", () => {
    expect(normalizeLocale("en-US")).toBe("en");
    expect(normalizeLocale("zh_Hans_SG")).toBe("zh-CN");
    expect(normalizeLocale("zh-CN")).toBe("zh-CN");
    expect(normalizeLocale("es-MX")).toBe("es");
    expect(normalizeLocale("ja-JP")).toBe("ja");
    expect(normalizeLocale("fr-FR")).toBeUndefined();
  });

  it("prefers a persisted locale and otherwise uses navigator language", () => {
    const stored = memoryStorage({ [LOCALE_STORAGE_KEY]: "en" });
    expect(resolveInitialLocale({ storage: stored, navigatorLanguage: "zh-CN" })).toBe("en");
    expect(resolveInitialLocale({ storage: memoryStorage(), navigatorLanguage: "zh-Hans" })).toBe("zh-CN");
    expect(resolveInitialLocale({ storage: memoryStorage(), navigatorLanguage: "es-MX" })).toBe("es");
    expect(resolveInitialLocale({ storage: memoryStorage(), navigatorLanguage: "ja-JP" })).toBe("ja");
    expect(resolveInitialLocale({ storage: memoryStorage(), navigatorLanguage: "de-DE" })).toBe(DEFAULT_LOCALE);
  });

  it("survives inaccessible storage and persists when storage is available", () => {
    const blocked = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    };
    expect(resolveInitialLocale({ storage: blocked, navigatorLanguage: "zh-CN" })).toBe("zh-CN");
    expect(persistLocale("en", blocked)).toBe(false);

    const storage = memoryStorage();
    expect(persistLocale("zh-CN", storage)).toBe(true);
    expect(storage.value(LOCALE_STORAGE_KEY)).toBe("zh-CN");
  });

  it("translates typed keys and interpolates named values", () => {
    const key: TranslationKey = "controller.offlineDescription";
    expect(translate("en", key, { port: 47831 })).toContain("47831");
    expect(translate("zh-CN", "provision.successDescription", { name: "Helio" })).toBe("Helio 已可用于 Codex 工作。");
    expect(translate("zh-CN", "error.provisionBridgeUnavailable")).toBe("安全桌面工作机设置桥接器不可用");
    expect(translate("zh-CN", "integration.stale.fleetRevision", { from: 4, to: 5 })).toBe("电脑集群修订版本从 4 变为 5。");
    expect(translate("es", "home.addComputer")).toBe("Añadir computadora");
    expect(translate("ja", "home.addComputer")).toBe("コンピューターを追加");
    expect(translate("es", "rules.gpuTarget")).toBe("Preferir computadoras con NVIDIA");
    expect(translate("ja", "rules.predictableTitle")).toBe("予測可能な設計");
    expect(translate("es", "integration.pluginDescriptionShort")).toContain("puente MCP");
    expect(translate("ja", "provision.action.retryPassword")).toBe("修正したパスワードで再試行");
    expectTypeOf<Locale>().toEqualTypeOf<"en" | "zh-CN" | "es" | "ja">();
  });

  it("provides the resolved locale and translator to React consumers", () => {
    function Consumer() {
      const { locale, t } = useI18n();
      return <span lang={locale}>{t("home.addComputer")}</span>;
    }

    const html = renderToStaticMarkup(
      <I18nProvider storage={memoryStorage({ [LOCALE_STORAGE_KEY]: "zh-CN" })}>
        <Consumer />
      </I18nProvider>,
    );
    expect(html).toBe('<span lang="zh-CN">添加电脑</span>');
  });

  it("fails loudly when the hook is used without its provider", () => {
    function InvalidConsumer() {
      useI18n();
      return null;
    }
    expect(() => renderToStaticMarkup(<InvalidConsumer />)).toThrow("useI18n must be used within an I18nProvider");
  });
});
