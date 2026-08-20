import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const ppLanguage = {
  name: 'pp',
  scopeName: 'source.pp',
  patterns: [
    { include: '#comments' },
    { include: '#strings' },
    { include: '#numbers' },
    { include: '#keywords' },
    { include: '#types' },
  ],
  repository: {
    comments: {
      patterns: [
        { name: 'comment.line.double-slash.pp', begin: '//', end: '$' },
        { name: 'comment.block.pp', begin: '/\\*', end: '\\*/' },
      ],
    },
    strings: {
      patterns: [
        { name: 'string.quoted.double.pp', begin: '"', end: '"', patterns: [{ name: 'constant.character.escape.pp', match: '\\\\.' }] },
      ],
    },
    numbers: {
      patterns: [
        { name: 'constant.numeric.hex.pp', match: '\\b0[xX][0-9a-fA-F]+\\b' },
        { name: 'constant.numeric.float.pp', match: '\\b[0-9]+\\.[0-9]+\\b' },
        { name: 'constant.numeric.integer.pp', match: '\\b[0-9]+\\b' },
      ],
    },
    keywords: {
      patterns: [
        { name: 'keyword.control.pp', match: '\\b(fn|extern|if|else|return|let|while|for|in|break|continue|switch|import|static|as|defer)\\b' },
        { name: 'storage.type.pp', match: '\\b(struct|enum)\\b' },
        { name: 'constant.language.boolean.pp', match: '\\b(true|false)\\b' },
      ],
    },
    types: {
      patterns: [
        { name: 'support.type.pp', match: '\\b(void|int|float|bool|str|u8|u16|u32|u64)\\b' },
      ],
    },
  },
};

export default defineConfig({
  site: 'https://pengpeng-labs.github.io',
  base: '/xlc-lang',
  markdown: { shikiConfig: { langs: [ppLanguage] } },
  integrations: [
    starlight({
      title: 'pp-labs 教程',
      description: '从 pp-lang v0.3 到编译器、数据库与操作系统',
      defaultLocale: 'root',
      locales: {
        root: { label: '简体中文', lang: 'zh-CN' },
        en: { label: 'English', lang: 'en' },
      },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/pengpeng-labs/xlc-lang' }],
      editLink: {
        baseUrl: 'https://github.com/pengpeng-labs/xlc-lang/edit/main/tutorial/',
      },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        { label: '导览', items: [{ label: '四套教程', link: '/xlc-lang/' }] },
        {
          label: 'pplang v0.3',
          items: [
            { label: '语言总览', link: '/xlc-lang/pplang/v0-3/' },
            {
              label: '来源与设计',
              items: [{ autogenerate: { directory: 'pplang/v0-3/design' } }],
            },
            {
              label: '使用教程',
              items: [{ autogenerate: { directory: 'pplang/v0-3/guide' } }],
            },
            {
              label: '参考手册',
              items: [{ autogenerate: { directory: 'pplang/v0-3/reference' } }],
            },
          ],
        },
        {
          label: '后续教程',
          items: [
            { label: 'pplc 编译器', link: '/xlc-lang/pplc/' },
            { label: 'ppdb 数据库', link: '/xlc-lang/ppdb/' },
            { label: 'ppos 操作系统', link: '/xlc-lang/ppos/' },
          ],
        },
      ],
    }),
  ],
});
