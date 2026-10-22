// Everything: a card per live top-level agent, oldest first, with its child
// agents, and a Channels card once a channel exists. The server writes this
// file when it is missing: edit it to change Everything, delete it to get
// this one back on the next start.
export default async function Everything() {
  const agents = await query`SELECT id, parent FROM sessions
    WHERE kind = 'agent' AND lifecycle <> 'archived'
    ORDER BY created_at, id`
  const channels = await query`SELECT id FROM conversations
    WHERE kind = 'users' ORDER BY created_at, id`
  const page = (agent) => ({ page: `/_/sessions/${agent.id}` })
  return (
    <Sidebar name='Everything' icon='comment' home='/'>
      {agents.filter((agent) => agent.parent == null).map((top) => (
        <PageCard
          {...page(top)}
          children={agents.filter((agent) => agent.parent === top.id).map(page)}
        />
      ))}
      {channels.length > 0 && (
        <PageCard
          title='Channels'
          children={channels.map((channel) => ({
            page: `/_/conversations/${channel.id}`,
          }))}
        />
      )}
    </Sidebar>
  )
}
