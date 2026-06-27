'use strict';

const PRODUCTS = Object.freeze({
  nocturne: { id: 'nocturne', name: 'Vestido Nocturne', price: 89900,  category: 'vestidos' },
  velvet:   { id: 'velvet',   name: 'Conjunto Velvet',  price: 112000, category: 'conjuntos' },
  aurora:   { id: 'aurora',   name: 'Vestido Aurora',   price: 79500,  category: 'vestidos' },
  lumiere:  { id: 'lumiere',  name: 'Top Lumière',      price: 48000,  category: 'tops' },
  soiree:   { id: 'soiree',   name: 'Falda Soirée',     price: 62000,  category: 'faldas' },
  minuit:   { id: 'minuit',   name: 'Vestido Minuit',   price: 95000,  category: 'vestidos' },
});

const VALID_SIZES = Object.freeze(['XS', 'S', 'M', 'L', 'XL']);

function getProduct(id) {
  return Object.prototype.hasOwnProperty.call(PRODUCTS, id) ? PRODUCTS[id] : null;
}

module.exports = { PRODUCTS, VALID_SIZES, getProduct };
