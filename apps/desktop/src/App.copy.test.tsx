import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { App } from "./App";
import { I18nProvider, LOCALE_STORAGE_KEY } from "./i18n";

describe("desktop content hierarchy", () => {
  it("renders status and actions without promotional page copy", () => {
    const html = renderToStaticMarkup(
      <I18nProvider storage={{
        getItem: (key: string) => key === LOCALE_STORAGE_KEY ? "zh-CN" : null,
        setItem: () => {},
      }}>
        <App />
      </I18nProvider>,
    );

    for (const text of [
      "你的 Codex 电脑集群",
      "在一个界面查看 Codex 在哪里工作，以及为什么选择它。",
      "跟踪每次分配任务，从排队到验证产物。",
    ]) {
      expect(html).not.toContain(text);
    }
    expect(html).toContain("集群概览");
    expect(html).toContain("最近任务");
    expect(html).toContain("添加电脑");
    expect(html).not.toContain('class="page-hero"');
  });
});
