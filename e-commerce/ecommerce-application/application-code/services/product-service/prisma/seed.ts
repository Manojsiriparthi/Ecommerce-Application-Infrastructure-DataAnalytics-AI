import { PrismaClient } from '@prisma/client';
const prisma=new PrismaClient();
async function main(){await prisma.product.createMany({data:[
{name:'Classic T-Shirt',description:'Cotton everyday t-shirt',category:'T-Shirts',gender:'MEN',price:799,stock:100},
{name:'Slim Fit Jeans',description:'Comfort stretch denim',category:'Jeans',gender:'MEN',price:1799,stock:60},
{name:'Floral Dress',description:'Lightweight casual dress',category:'Dresses',gender:'WOMEN',price:2299,stock:40},
{name:'Women Sneakers',description:'Comfort daily sneakers',category:'Footwear',gender:'WOMEN',price:1999,stock:50}
]});}
main().finally(()=>prisma.$disconnect());
