import { chromium } from 'playwright';
const R='/home/nathan/code-stuff/scheme-benchmarking/knowledge/sources';
const jobs=[['cheney-nonrecursive-list-compacting-1970','10.1145/362790.362798'],
            ['morel-renvoise-partial-redundancy-elimination-1979','10.1145/359060.359069']];
const b=await chromium.launch({args:['--disable-blink-features=AutomationControlled']});
const ctx=await b.newContext({acceptDownloads:true,viewport:{width:1440,height:900},
  userAgent:'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36',
  locale:'en-US'});
await ctx.addInitScript(()=>{Object.defineProperty(navigator,'webdriver',{get:()=>undefined});});
for (const [slug,doi] of jobs){
  const p=await ctx.newPage();
  try{
    const land=await p.goto(`https://dl.acm.org/doi/${doi}`,{waitUntil:'domcontentloaded',timeout:60000});
    console.log(`  ${slug}: landing=${land?.status()}`);
    await p.waitForTimeout(8000);
    const title=await p.title(); console.log(`    title: ${title.slice(0,60)}`);
    if(land?.status()===200){
      const r=await p.goto(`https://dl.acm.org/doi/pdf/${doi}`,{waitUntil:'domcontentloaded',timeout:60000});
      await p.waitForTimeout(5000);
      const ct=r?.headers()['content-type']||''; console.log(`    pdf=${r?.status()} ct=${ct.slice(0,24)}`);
      if(ct.includes('pdf')){const buf=await r.body();const fs=await import('fs');
        fs.writeFileSync(`${R}/${slug}.pdf`,buf);console.log(`    SAVED ${buf.length}`);}
    }
  }catch(e){console.log(`  ${slug}: ERR ${String(e).slice(0,70)}`);}
  await p.close();
}
await b.close();
