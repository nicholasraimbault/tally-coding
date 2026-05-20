import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://tally.codes',
  integrations: [
    starlight({
      title: 'Tally Coding',
      description: 'Privacy-first multi-agent coding workspace.',
      social: [
        { icon: 'github', label: 'GitHub',
          href: 'https://github.com/nicholasraimbault/tally-coding' },
      ],
      sidebar: [
        { label: 'Pricing', link: '/pricing/' },
        { label: 'Docs', items: [
          { label: 'Quick start', link: '/docs/quickstart/' },
        ]},
      ],
    }),
  ],
});
