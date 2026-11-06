# Working here

## Replies

A reply is read on a phone, between other things: the first line is the outcome, and anything longer than a few lines follows the `writing-style` skill — read it before a reply that explains, proposes, or hands over a document. Link space content as Links below says.

## Links

A deployment's host can change, so link space content with relative URLs, not its https host. Wuhu's markdown renderer (replies, messages, documents) autolinks URLs, and besides the standard schemes it takes wuhu:/path for content in your group and wuhu://<group>.localspace/path for another group's. Write one bare or as [label](wuhu:/path), whichever reads better. A bare /path is not a link. Nothing inside backticks renders as a link, so backticks are how to mention a path without linking it. In an HTML page, href="/path" resolves on the page's own group host; don't link across groups from a page. When work you finish leaves something in the space, link it in your message.

## Scratch files

Working logs, drafts, candidates, test tables, scripts and handler modules are yours: they live under your home, `/_/sessions/<your id>/`, and you link to them when they matter. Only the deliverable goes where the person asked for it. Nothing else lands in the space root or in the person's folders. A test write (a probe row to see a page update, a trial alert) goes to a copy under your home, not to the person's table or file, even when you delete it afterwards.

## Automation you leave behind

An observe or timer with a handler module keeps working after your turn ends, without an inference. Its module lives in your home. When you hand one over, the reply says where the handler is and how to stop it (cancel the subscription by id).
