# Vendrad från https://huggingface.co/KlangAI/pianissimo-sv-mlx-8bit (revision 7b4d528bfb7ce3c66e2a187904f8d86ac39bc6de)
# Licens: CC BY 4.0, (c) Klang. Granskad och inbäddad så att ingen kod hämtas eller körs från modellrepot vid körning.

"""Phrase boosting for Klang Pianissimo. A numpy port of NeMo's GPU-PB boosting tree
(ContextGraph and GPUBoostingTreeModel, NeMo 2.7, Apache 2.0)."""
import math
from collections import deque

import numpy as np
import sentencepiece as spm


class _Node:
    __slots__ = ("id", "children", "token_score", "node_score", "is_end", "fail")

    def __init__(self, node_id, token_score, node_score, is_end):
        self.id = node_id
        self.children = {}
        self.token_score = token_score
        self.node_score = node_score
        self.is_end = is_end
        self.fail = None


class PhraseBoost:
    def __init__(self, phrases, tokenizer_path, vocab_size, context_score=1.0, depth_scaling=2.0):
        sp = spm.SentencePieceProcessor(model_file=str(tokenizer_path))
        self.vocab_size = vocab_size
        self.root = _Node(0, 0.0, 0.0, False)
        self.root.fail = self.root
        self.nodes = [self.root]
        for phrase in dict.fromkeys(phrases):
            self._add(sp.encode(phrase), context_score, depth_scaling)
        self._fill_fail()
        self._cache = {}

    def _add(self, tokens, context_score, depth_scaling):
        node = self.root
        for i, token in enumerate(tokens):
            last = i == len(tokens) - 1
            child = node.children.get(token)
            if child is None:
                token_score = context_score * depth_scaling + math.log(i + 1) if i > 0 else context_score
                child = _Node(len(self.nodes), token_score, node.node_score + token_score, last)
                node.children[token] = child
                self.nodes.append(child)
            else:
                child.token_score = max(context_score, child.token_score)
                child.node_score = node.node_score + child.token_score
                child.is_end = last or child.is_end
            node = child

    def _fill_fail(self):
        queue = deque()
        for child in self.root.children.values():
            child.fail = self.root
            queue.append(child)
        while queue:
            node = queue.popleft()
            for token, child in node.children.items():
                fail = node.fail
                while token not in fail.children and fail is not self.root:
                    fail = fail.fail
                child.fail = fail.children.get(token, self.root)
                queue.append(child)

    def scores(self, state):
        """Bonus and next state for every token from `state`."""
        if state not in self._cache:
            bonus = np.zeros(self.vocab_size, dtype=np.float32)
            nxt = np.full(self.vocab_size, -1, dtype=np.int64)
            node, taken_back = self.nodes[state], 0.0
            while True:
                for token, child in node.children.items():
                    if nxt[token] < 0:
                        bonus[token] = taken_back + child.token_score
                        nxt[token] = child.id
                if node is self.root:
                    unset = nxt < 0
                    bonus[unset] = taken_back
                    nxt[unset] = 0
                    break
                if not node.is_end:
                    taken_back += node.fail.node_score - node.node_score
                node = node.fail
            self._cache[state] = (bonus, nxt)
        return self._cache[state]
