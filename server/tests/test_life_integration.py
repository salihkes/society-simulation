"""Real Mind/Brain/WorldStore wiring; services replaced, all files temporary.
Run with the server's Python environment for the optional application dependencies.
"""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

AVAILABLE = all(importlib.util.find_spec(n) for n in ('aiohttp', 'frontmatter'))

@unittest.skipUnless(AVAILABLE, 'run with the server venv for application integration checks')
class MindIntegration(unittest.IsolatedAsyncioTestCase):
    async def test_authoritative_observation_to_action_and_memory(self):
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from mind import Mind
        with tempfile.TemporaryDirectory() as root:
            cards = Path(root)/'cards'; cards.mkdir()
            (cards/'alice.md').write_text('# Alice\nA curious student who cares about her friend.\n')
            (Path(root)/'clock.json').write_text('{"mode":"fixed","hour":9}')
            outbound = []
            async def send(msg): outbound.append(msg)
            m = Mind(root, send, send)
            try:
                await m.on_world_report({'workspace':'test', 'places':[], 'residents':[{'id':'alice','student':True}]})
                # Definitions edited by hand often omit the redundant id field.
                m.store.residents['alice'].pop('id', None)
                self.assertIn('curious student', m.brain._persona('r_alice'))
                await m.on_observations({'hour':9,'day':1,'obs':[{'who':'r_alice','life_view':{
                    'school':'School','phase':'class','seated':True,'nearby':{},'available':['study','continue'],'manual':False}}]})
                self.assertEqual(m.store.recent('r_alice'), [], 'perception snapshots must not flood durable memory')
                with patch.object(m.brain.memory, 'context', AsyncMock(return_value='')), patch.object(m.brain.llm, 'chat', AsyncMock(return_value=json.dumps({
                    'action':{'do':'study','seconds':30}, 'goal':'Understand today', 'reason':'I want to ask a better question'}))):
                    await m.brain.life.decide('r_alice')
                action = next(msg for msg in outbound if msg['type']=='life_cmd')
                self.assertEqual(action['action']['do'],'study')
                await m.on_observations({'obs':[{'who':'r_alice','life_result':{'id':action['action_id'],'status':'completed','reason':'studied'}}]})
                self.assertIsNone(m.brain.life.state('r_alice')['pending'])
                self.assertTrue(any('life_outcome' in e for e in m.store.recent('r_alice')))
                replies=[]
                async def reply(msg): replies.append(msg)
                await m.command({'cmd':'life','op':'pause','id':'alice'},reply)
                self.assertTrue(replies[-1]['ok'])
                count=len(outbound)
                await m.push_intents('r_alice',[{'do':'attend','place':'School'}])
                self.assertEqual(len(outbound),count,'school automation must respect director control')
            finally:
                for task in m.brain._tasks: task.cancel()
                await m.brain.llm.close()
                m.brain.memory.store.db().close()
