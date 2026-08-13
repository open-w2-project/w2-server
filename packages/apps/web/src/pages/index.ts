import type { GetStaticProps } from "next";

export const getStaticProps: GetStaticProps = () => Promise.resolve({ props: {} });

export default () => null;
