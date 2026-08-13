import { Head, Html, Main, NextScript, type DocumentProps } from "next/document";

export default ({ locale }: DocumentProps) => (
  <Html lang={locale}>
    <Head />
    <body>
      <Main />
      <NextScript />
    </body>
  </Html>
);
